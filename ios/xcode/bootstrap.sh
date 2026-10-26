#!/bin/bash
# Xcode 프로젝트를 준비한다 (P12): Xcode Cloud의 ci_post_clone.sh, 처음 워크플로를 만드는 Mac, GitHub의 확인 작업이 같이 쓴다.
#
# 1. 소스 열쇠(ios-sdk.py key)로 GitHub Release의 iOS SDK 묶음(libobs·플러그인·의존성 정적 라이브러리)을 받아 .sdk/에 푼다
#    (--sdk-file로 파일을 주면 그것을 쓴다. 아직 없으면 GitHub 빌드가 올릴 때까지 1분씩 10번 기다린다)
# 2. Xcode Cloud면 release xcode-cloud-main의 main-build.json에서 이 커밋의 GitHub 실행 번호를 읽는다 (버전 0.1.<번호>)
# 3. VRMKit을 받고, Info.plist와 SDK.xcconfig를 만든 뒤 XcodeGen으로 xcode/Broadcast.xcodeproj를 만든다
#
# 환경 변수: DEVELOPMENT_TEAM(서명할 팀 ID, 없으면 서명 설정 없이), YOUTUBE_CLIENT_ID(Xcode Cloud 비밀값),
# SDK_REPOSITORY(기본 VideiN/iPadOS-broadcasting)
# 사용법: bash ios/xcode/bootstrap.sh [--sdk-file <ios-sdk.tar.gz>]

set -euo pipefail

repo=$(cd "$(dirname "$0")/../.." && pwd)
sdk_tool="$repo/ios/scripts/ios-sdk.py"
repository=${SDK_REPOSITORY:-VideiN/iPadOS-broadcasting}
xcodegen_version=2.46.0
xcodegen_sha256=4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806

sdk_file=""
while [ $# -gt 0 ]; do
  case $1 in
    --sdk-file)
      sdk_file=$2
      shift 2
      ;;
    *)
      echo "usage: bootstrap.sh [--sdk-file <ios-sdk.tar.gz>]" >&2
      exit 2
      ;;
  esac
done

key=$(python3 "$sdk_tool" key)
echo "ios sdk key: $key"
mkdir -p "$repo/.sdk"

# 1. SDK 묶음
if [ -z "$sdk_file" ]; then
  sdk_file="$repo/.sdk/ios-sdk-$key.tar.gz"
  url="https://github.com/$repository/releases/download/ios-sdk-$key/ios-sdk.tar.gz"
  if [ ! -s "$sdk_file" ]; then
    for attempt in $(seq 1 10); do
      if curl -fsSL --retry 3 -o "$sdk_file.part" "$url"; then
        mv "$sdk_file.part" "$sdk_file"
        break
      fi
      rm -f "$sdk_file.part"
      if [ "$attempt" = 10 ]; then
        echo "error: no iOS SDK for this source ($url)." >&2
        echo "  The GitHub Actions build of this commit publishes it (job 'iOS SDK release'); check that it passed." >&2
        exit 1
      fi
      echo "iOS SDK ios-sdk-$key is not published yet, waiting ($attempt/10)"
      sleep 60
    done
  fi
fi
rm -rf "$repo/.sdk/ios-sdk"
tar -xzf "$sdk_file" -C "$repo/.sdk"
sdk_key=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["key"])' "$repo/.sdk/ios-sdk/sdk.json")
if [ "$sdk_key" != "$key" ]; then
  echo "error: the iOS SDK is for source $sdk_key, this checkout is $key" >&2
  exit 1
fi
echo "ios sdk: $(python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); print(d["obs_version"], d["sdk"], d["xcode"], "from", d["commit"][:7])' "$repo/.sdk/ios-sdk/sdk.json")"

# 2. Xcode Cloud: 이 커밋을 빌드한 GitHub 실행 (버전 번호와 설정 › 정보의 빌드 줄)
if [ -n "${CI_COMMIT:-}" ]; then
  main_build="$repo/.sdk/main-build.json"
  if curl -fsSL --retry 3 -o "$main_build" "https://github.com/$repository/releases/download/xcode-cloud-main/main-build.json"; then
    eval "$(python3 - "$main_build" "$CI_COMMIT" << 'PYEOF'
import json, shlex, sys
build = json.load(open(sys.argv[1]))
if build.get("commit") == sys.argv[2]:
    for name, key in (("APP_BUILD_RUN", "run"), ("APP_BUILD_RUN_ID", "run_id"), ("APP_BUILD_REPOSITORY", "repository")):
        print(f"export {name}={shlex.quote(str(build.get(key, '')))}")
else:
    other = str(build.get("commit", "?"))[:7]
    print(f"echo 'main-build.json is for {other}, not this commit; version 0.1.0'")
PYEOF
)"
  else
    echo "no main-build.json yet; version 0.1.0"
  fi
fi

# 3. VRMKit, Info.plist, xcconfig, 프로젝트
python3 "$sdk_tool" vrmkit "$repo/.vrmkit/src"
python3 "$sdk_tool" info-plist "$repo/xcode/Generated/Info.plist"
python3 "$sdk_tool" xcconfig "$repo/.sdk/ios-sdk" "$repo/xcode/Generated/SDK.xcconfig"

tools="$repo/.tools/xcodegen-$xcodegen_version"
if [ ! -x "$tools/xcodegen/bin/xcodegen" ]; then
  rm -rf "$tools"
  mkdir -p "$tools"
  curl -fsSL --retry 3 -o "$tools/xcodegen.zip" \
    "https://github.com/yonaskolb/XcodeGen/releases/download/$xcodegen_version/xcodegen.zip"
  echo "$xcodegen_sha256  $tools/xcodegen.zip" | shasum -a 256 -c -
  unzip -q "$tools/xcodegen.zip" -d "$tools"
fi
"$tools/xcodegen/bin/xcodegen" generate --spec "$repo/xcode/project.yml" --project "$repo/xcode"
echo "ready: $repo/xcode/Broadcast.xcodeproj (scheme Broadcast)"
