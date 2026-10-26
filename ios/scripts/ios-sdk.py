#!/usr/bin/env python3
"""Xcode Cloud가 앱을 빌드할 때 쓰는 iOS SDK 묶음과 Xcode 프로젝트 준비 (P12).

GitHub Actions의 CMake/Ninja 빌드(libobs, 플러그인, 의존성)를 정적 라이브러리 묶음으로 만들어 Release에 올리고,
Xcode Cloud(와 처음 워크플로를 만드는 Mac)는 그 묶음으로 XcodeGen 프로젝트(xcode/project.yml)를 빌드한다.
앱 코드(Swift, C 브리지 app/Core, VRMKit)는 Xcode가 컴파일한다.

- key: 묶음을 고르는 열쇠. obs-studio·ios/deps·ios/config.env·이 파일의 git 트리 해시로 만든다 (같은 소스면 같은 묶음)
- package <BUILD_DIR> <DEPS_DIR> <나갈 .tar.gz>: CMake 빌드에서 app-core가 컴파일된 옵션(compile_commands.json)과
  앱의 링크 명령(ninja -t commands)을 읽어, 필요한 정적 라이브러리·빌드가 만든 헤더·의존성 라이선스를 묶는다
- xcconfig <SDK 폴더> <나갈 .xcconfig>: 묶음의 flags.json을 Xcode 설정으로 (경로는 $(REPO_ROOT)·$(SDK_DIR) 기준)
- info-plist <나갈 Info.plist>: app/Info.plist.in을 CMake와 같은 값으로 채운다. DT… 키는 Xcode가 넣으므로 뺀다
- vrmkit <나갈 폴더>: app/CMakeLists.txt와 같은 커밋의 VRMKit을 받아(SHA-256 확인) 같은 패치를 한다

경로 표기: flags.json 안에서 ${REPO}는 저장소, ${SDK}는 풀어 둔 묶음 폴더다.
"""

import hashlib
import json
import os
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request

REPO = os.path.realpath(os.path.join(os.path.dirname(__file__), "..", ".."))
# 앱 쪽 코드: 묶음에 넣지 않고 Xcode가 컴파일한다
APP_LIBRARIES = {"libapp-core.a", "libVRMKit.a", "libVRMKitRuntime.a", "libVRMRealityKit.a", "libSIMDCompat.a"}


def fail(message):
    print(f"::error::{message}" if os.environ.get("GITHUB_ACTIONS") else f"error: {message}", flush=True)
    sys.exit(1)


def git(*args):
    return subprocess.run(["git", "-C", REPO, *args], check=True, capture_output=True, text=True).stdout.strip()


def source_key():
    parts = [f"{path}:{git('rev-parse', f'HEAD:{path}')}"
             for path in ("obs-studio", "ios/deps", "ios/config.env", "ios/scripts/ios-sdk.py")]
    return hashlib.sha256("\n".join(parts).encode()).hexdigest()[:12]


def config_env():
    values = {}
    with open(os.path.join(REPO, "ios", "config.env"), encoding="utf-8") as file:
        for line in file:
            if "=" in line and not line.lstrip().startswith("#"):
                name, value = line.strip().split("=", 1)
                values[name] = value
    return values


def app_cmake():
    with open(os.path.join(REPO, "app", "CMakeLists.txt"), encoding="utf-8") as file:
        return file.read()


def cmake_value(name):
    match = re.search(rf'set\({name} "?([^")\s]+)"?\)', app_cmake())
    if not match:
        fail(f"{name} not found in app/CMakeLists.txt")
    return match.group(1)


# MARK: package

def inside(path, root):
    return os.path.commonpath([path, root]) == root


def copy_headers(source, destination):
    """폴더의 헤더만 (.h, .hpp, .inc) 옮긴다"""
    for directory, _, files in os.walk(source):
        for name in files:
            if name.endswith((".h", ".hpp", ".inc", ".modulemap")):
                target = os.path.join(destination, os.path.relpath(directory, source), name)
                os.makedirs(os.path.dirname(target), exist_ok=True)
                shutil.copy2(os.path.join(directory, name), target)


class Packer:
    def __init__(self, build_dir, deps_dir, staging):
        self.build_dir = os.path.realpath(build_dir)
        self.deps_dir = os.path.realpath(deps_dir)
        self.staging = staging
        self.copied = set()

    def include_dir(self, path):
        """헤더 폴더를 묶음 기준 표기로. 빌드가 만든 것과 의존성 헤더는 묶음에 복사한다. 시스템 SDK는 None"""
        path = os.path.realpath(path)
        for root, prefix in ((self.build_dir, "build"), (self.deps_dir, "deps")):
            if inside(path, root):
                relative = os.path.join("include", prefix, os.path.relpath(path, root))
                if relative not in self.copied:
                    self.copied.add(relative)
                    copy_headers(path, os.path.join(self.staging, relative))
                return "${SDK}/" + relative.replace(os.sep, "/")
        if inside(path, REPO):
            return "${REPO}/" + os.path.relpath(path, REPO).replace(os.sep, "/")
        if "/Xcode" in path or ".sdk/" in path or path.startswith("/usr/"):
            return None
        fail(f"include directory outside the repository, build and deps: {path}")

    def library(self, path):
        path = os.path.realpath(path if os.path.isabs(path) else os.path.join(self.build_dir, path))
        for root, prefix in ((self.build_dir, "build"), (self.deps_dir, "deps")):
            if inside(path, root):
                relative = os.path.join("lib", prefix, os.path.relpath(path, root))
                target = os.path.join(self.staging, relative)
                os.makedirs(os.path.dirname(target), exist_ok=True)
                shutil.copy2(path, target)
                return "${SDK}/" + relative.replace(os.sep, "/")
        fail(f"static library outside the build and deps: {path}")


def compile_flags(packer):
    """app-core(app/Core)를 컴파일한 옵션 중 Xcode에 옮길 것: 헤더 경로, 정의, C 표준"""
    with open(os.path.join(packer.build_dir, "compile_commands.json"), encoding="utf-8") as file:
        commands = json.load(file)
    core = os.path.join(REPO, "app", "Core") + os.sep
    entries = [entry for entry in commands if os.path.realpath(entry["file"]).startswith(core)]
    if not entries:
        fail("no app/Core entries in compile_commands.json (configure with -DCMAKE_EXPORT_COMPILE_COMMANDS=ON)")

    flags = []
    seen = set()
    for entry in entries:
        arguments = entry.get("arguments") or shlex.split(entry["command"])
        directory = entry["directory"]
        index = 0
        while index < len(arguments):
            argument = arguments[index]
            option = value = None
            if argument in ("-I", "-isystem", "-iquote") and index + 1 < len(arguments):
                option, value = argument, arguments[index + 1]
                index += 1
            elif argument.startswith("-isystem") and len(argument) > len("-isystem"):
                option, value = "-isystem", argument[len("-isystem"):]
            elif argument.startswith("-I") and len(argument) > 2:
                option, value = "-I", argument[2:]

            if option:
                mapped = packer.include_dir(value if os.path.isabs(value) else os.path.join(directory, value))
                flag = ("-I" + mapped,) if mapped and option == "-I" else (option, mapped) if mapped else None
            elif argument.startswith(("-D", "-std=")):
                flag = (argument,)
            else:
                flag = None
            if flag and flag not in seen:
                seen.add(flag)
                flags.extend(flag)
            index += 1
    return flags


def link_flags(packer):
    """앱의 링크 명령에서 정적 라이브러리(앱 코드 것은 빼고), 프레임워크, -l"""
    target = "app/Broadcast.app/Broadcast"
    lines = subprocess.run(["ninja", "-C", packer.build_dir, "-t", "commands", target],
                           check=True, capture_output=True, text=True).stdout.strip().splitlines()
    # 링크 줄은 ": && swiftc … -o app/Broadcast.app/Broadcast … && :" 꼴이고 POST_BUILD 명령이 &&로 이어진다.
    # 그 가운데 출력이 앱 실행 파일인 명령을 고른다
    segments = [segment for line in lines for segment in line.split(" && ")]
    link = [segment for segment in segments if f"-o {target}" in segment or f"-o {packer.build_dir}/{target}" in segment]
    if not link:
        fail(f"ninja did not print the link command of {target}")
    arguments = shlex.split(link[-1])
    # 링커에 넘기는 감싸기(-Xlinker x, -Wl,a,b)는 벗긴다
    plain = []
    index = 0
    while index < len(arguments):
        argument = arguments[index]
        if argument == "-Xlinker" and index + 1 < len(arguments):
            plain.append(arguments[index + 1])
            index += 2
            continue
        plain.extend(argument[4:].split(",") if argument.startswith("-Wl,") else [argument])
        index += 1

    search_dirs = [value[2:] for value in plain if value.startswith("-L") and len(value) > 2]
    flags = []
    ignored = []
    index = 0
    while index < len(plain):
        argument = plain[index]
        if argument in ("-framework", "-weak_framework") and index + 1 < len(plain):
            pair = [argument, plain[index + 1]]
            if not any(flags[i:i + 2] == pair for i in range(len(flags))):
                flags.extend(pair)
            index += 2
            continue
        library = None
        if argument.endswith(".a"):
            library = argument
        elif re.fullmatch(r"-l[\w+.-]+", argument):
            # -L의 폴더(빌드·의존성)에 있는 정적 라이브러리면 그 파일로, 아니면 시스템 라이브러리 (-lc++, -lz …)
            found = [os.path.join(d, f"lib{argument[2:]}.a") for d in search_dirs
                     if os.path.exists(os.path.join(d, f"lib{argument[2:]}.a"))]
            if found:
                library = found[0]
            elif argument not in flags:
                flags.append(argument)
        elif argument.startswith("-") and not argument.startswith("-L"):
            ignored.append(argument)
        if library and os.path.basename(library) not in APP_LIBRARIES:
            mapped = packer.library(library)
            if mapped not in flags:
                flags.append(mapped)
        index += 1
    print(f"link: {sum(f.endswith('.a') for f in flags)} static libraries, "
          f"{flags.count('-framework') + flags.count('-weak_framework')} frameworks, "
          f"{sum(f.startswith('-l') for f in flags)} -l; not carried over: {' '.join(sorted(set(ignored)))}")
    return flags


def package(build_dir, deps_dir, out):
    staging = tempfile.mkdtemp(prefix="ios-sdk.")
    packer = Packer(build_dir, deps_dir, staging)
    cflags = compile_flags(packer)
    ldflags = link_flags(packer)

    licenses = os.path.join(packer.deps_dir, "share", "licenses")
    if os.path.isdir(licenses):
        shutil.copytree(licenses, os.path.join(staging, "share", "licenses"))

    with open(os.path.join(staging, "flags.json"), "w", encoding="utf-8") as file:
        json.dump({"cflags": cflags, "ldflags": ldflags}, file, indent=1)
    sdk_version = subprocess.run(["xcrun", "--sdk", "iphoneos", "--show-sdk-version"], capture_output=True,
                                 text=True).stdout.strip()
    xcode = subprocess.run(["xcodebuild", "-version"], capture_output=True, text=True).stdout.split("\n")[0]
    info = {
        "key": source_key(), "commit": git("rev-parse", "HEAD"), "obs_version": config_env().get("OBS_VERSION"),
        "deployment_target": config_env().get("IOS_DEPLOYMENT_TARGET"), "sdk": f"iphoneos{sdk_version}",
        "xcode": xcode, "created": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    with open(os.path.join(staging, "sdk.json"), "w", encoding="utf-8") as file:
        json.dump(info, file, indent=1)

    with tarfile.open(out, "w:gz") as archive:
        archive.add(staging, arcname="ios-sdk")
    shutil.rmtree(staging)
    print(f"ios sdk {info['key']}: {os.path.getsize(out) / 1e6:.1f} MB, {len(cflags)} compile flags, "
          f"{len(ldflags)} link flags -> {out}")


# MARK: xcconfig

def xcconfig(sdk_dir, out):
    with open(os.path.join(sdk_dir, "flags.json"), encoding="utf-8") as file:
        flags = json.load(file)

    def setting(values):
        mapped = [value.replace("${REPO}", "$(REPO_ROOT)").replace("${SDK}", "$(SDK_DIR)") for value in values]
        return " ".join(f'"{value}"' for value in mapped)

    deployment_target = config_env()["IOS_DEPLOYMENT_TARGET"]
    lines = [
        "// ios/scripts/ios-sdk.py xcconfig가 만든다. 고치지 않는다 (bootstrap.sh가 다시 만든다)",
        "REPO_ROOT = $(SRCROOT)/..",
        "SDK_DIR = $(REPO_ROOT)/.sdk/ios-sdk",
        "VRMKIT_DIR = $(REPO_ROOT)/.vrmkit/src",
        f"IPHONEOS_DEPLOYMENT_TARGET = {deployment_target}",
        f"SDK_CFLAGS = {setting(flags['cflags'])}",
        f"SDK_LDFLAGS = {setting(flags['ldflags'])}",
        # Xcode Cloud는 빌드 번호를 CI_BUILD_NUMBER로 준다. 그 밖(Mac, GitHub 확인)은 1
        f"APP_BUILD_NUMBER = {os.environ.get('CI_BUILD_NUMBER') or 1}",
    ]
    team = os.environ.get("DEVELOPMENT_TEAM", "").strip()
    if team:
        if not re.fullmatch(r"[A-Z0-9]{10}", team):
            fail("DEVELOPMENT_TEAM is not a 10-character team ID")
        lines.append(f"DEVELOPMENT_TEAM = {team}")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as file:
        file.write("\n".join(lines) + "\n")
    print(f"xcconfig: {len(flags['cflags'])} compile flags, {len(flags['ldflags'])} link flags -> {out}")


# MARK: Info.plist

def info_plist(out):
    run = os.environ.get("APP_BUILD_RUN", "0")
    youtube = os.environ.get("YOUTUBE_CLIENT_ID", "").strip()
    if youtube and not re.fullmatch(r"[0-9]+-[0-9A-Za-z_]+\.apps\.googleusercontent\.com", youtube):
        fail("YOUTUBE_CLIENT_ID is not an iOS OAuth client ID (...apps.googleusercontent.com)")
    commit = os.environ.get("CI_COMMIT") or git("rev-parse", "HEAD")
    branch = os.environ.get("CI_BRANCH") or git("rev-parse", "--abbrev-ref", "HEAD")
    values = {
        "APP_DISPLAY_NAME": cmake_value("APP_DISPLAY_NAME"),
        "APP_EXECUTABLE": cmake_value("APP_EXECUTABLE"),
        "APP_BUNDLE_ID": cmake_value("APP_BUNDLE_ID"),
        # LiveContainer·TestFlight 목록에서 GitHub 실행 번호로 알아보게 (app/CMakeLists.txt와 같다)
        "APP_VERSION": f"0.1.{run}",
        "APP_BUILD_NUMBER": "$(CURRENT_PROJECT_VERSION)",
        "APP_BUILD_RUN": run,
        "APP_BUILD_RUN_ID": os.environ.get("APP_BUILD_RUN_ID", ""),
        "APP_BUILD_BRANCH": branch,
        "APP_BUILD_COMMIT": commit,
        "APP_BUILD_REPOSITORY": os.environ.get("APP_BUILD_REPOSITORY", ""),
        "APP_BUILD_TIME": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "APP_YOUTUBE_CLIENT_HEX": youtube.encode().hex(),
        "CMAKE_OSX_DEPLOYMENT_TARGET": config_env()["IOS_DEPLOYMENT_TARGET"],
    }
    with open(os.path.join(REPO, "app", "Info.plist.in"), encoding="utf-8") as file:
        template = file.read()

    def substitute(match):
        value = values.get(match.group(1), "")
        return value.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

    plist = plistlib.loads(re.sub(r"@([A-Z_]+)@", substitute, template).encode())
    # Xcode가 빌드할 때 넣는 값 (CMake 빌드는 직접 넣었다)
    for key in list(plist):
        if key.startswith("DT") or key in ("BuildMachineOSBuild", "CFBundleSupportedPlatforms", "MinimumOSVersion"):
            del plist[key]
    plist.setdefault("BroadcastBuild", {})["XcodeCloudBuild"] = os.environ.get("CI_BUILD_NUMBER", "")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "wb") as file:
        plistlib.dump(plist, file)
    print(f"Info.plist: version {values['APP_VERSION']}, branch {branch}, commit {commit[:7]}, "
          f"YouTube client {'built in' if youtube else 'none'} -> {out}")


# MARK: VRMKit

def vrmkit(out):
    commit = cmake_value("VRMKIT_COMMIT")
    expected = re.search(r"URL_HASH SHA256=([0-9a-f]{64})", app_cmake()).group(1)
    marker = os.path.join(out, ".commit")
    if os.path.exists(marker) and open(marker).read().strip() == commit:
        print(f"VRMKit {commit[:7]}: already there")
        return
    url = f"https://github.com/tattn/VRMKit/archive/{commit}.tar.gz"
    with urllib.request.urlopen(url, timeout=120) as response:
        data = response.read()
    if hashlib.sha256(data).hexdigest() != expected:
        fail("VRMKit tarball SHA-256 does not match app/CMakeLists.txt")
    shutil.rmtree(out, ignore_errors=True)
    staging = tempfile.mkdtemp(prefix="vrmkit.")
    archive_path = os.path.join(staging, "vrmkit.tar.gz")
    with open(archive_path, "wb") as file:
        file.write(data)
    with tarfile.open(archive_path) as archive:
        archive.extractall(staging)
    top = next(name for name in os.listdir(staging) if name.startswith("VRMKit-"))
    shutil.move(os.path.join(staging, top), out)
    shutil.rmtree(staging)

    # app/CMakeLists.txt와 같은 패치: Swift 6.4 전 컴파일러가 클로저 안의 이름을 선언 중인 지역 상수로 읽는다
    patched = os.path.join(out, "Sources", "VRMRealityKit", "Loading", "GLTFSceneBuilder.swift")
    with open(patched, encoding="utf-8") as file:
        content = file.read()
    content = content.replace("{ try skeleton(withSkinIndex: $0) }", "{ try self.skeleton(withSkinIndex: $0) }")
    with open(patched, "w", encoding="utf-8") as file:
        file.write(content)
    with open(marker, "w") as file:
        file.write(commit + "\n")
    print(f"VRMKit {commit[:7]} -> {out}")


def main():
    args = sys.argv[1:]
    if args == ["key"]:
        print(source_key())
    elif len(args) == 4 and args[0] == "package":
        package(*args[1:])
    elif len(args) == 3 and args[0] == "xcconfig":
        xcconfig(*args[1:])
    elif len(args) == 2 and args[0] == "info-plist":
        info_plist(args[1])
    elif len(args) == 2 and args[0] == "vrmkit":
        vrmkit(args[1])
    else:
        print(__doc__)
        sys.exit(2)


if __name__ == "__main__":
    main()
