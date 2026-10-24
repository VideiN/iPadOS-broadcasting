#!/usr/bin/env python3
"""App Store Connect API를 조금 쓴다 (CI의 TestFlight 작업, 2026-10-24).

- app-id <번들 ID>: 그 번들 ID의 앱 번호(Apple ID)를 찍는다. altool이 계정에 앱이 여럿이면 엉뚱한 앱을 고르는 일이
  있어(Xcode 26) --apple-id로 넘긴다
- wait-build <번들 ID> <빌드 번호(CFBundleVersion)> <분>: 올린 빌드가 App Store Connect에서 처리되어 VALID가
  될 때까지 기다린다. FAILED·INVALID면 실패, 시간 안에 안 끝나면 경고만 남긴다 (처리가 늦을 때가 있다)

환경 변수 ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8(키 파일 내용)로 인증한다. 토큰은 ES256 JWT를 openssl로 서명해
만든다 (러너에 따로 설치할 것이 없게). 키와 토큰은 찍지 않는다.
"""

import base64
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.appstoreconnect.apple.com/v1"


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def der_to_raw(der):
    """openssl이 내는 ECDSA 서명(DER: SEQUENCE { INTEGER r, INTEGER s })을 JWT의 r||s (32바이트씩)로"""
    if der[0] != 0x30:
        raise ValueError("unexpected signature format")
    index = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    values = []
    for _ in range(2):
        if der[index] != 0x02:
            raise ValueError("unexpected signature format")
        length = der[index + 1]
        values.append(der[index + 2:index + 2 + length].lstrip(b"\0").rjust(32, b"\0"))
        index += 2 + length
    return values[0] + values[1]


def token():
    key_id = os.environ["ASC_KEY_ID"].strip()
    issuer = os.environ["ASC_ISSUER_ID"].strip()
    key = os.environ["ASC_KEY_P8"].strip()
    now = int(time.time())
    header = b64url(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
    payload = b64url(json.dumps({"iss": issuer, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"}).encode())
    signing_input = f"{header}.{payload}".encode()
    handle, path = tempfile.mkstemp(suffix=".p8")
    try:
        with os.fdopen(handle, "w") as file:
            file.write(key + "\n")
        result = subprocess.run(["openssl", "dgst", "-sha256", "-sign", path], input=signing_input,
                                capture_output=True, check=False)
    finally:
        os.remove(path)
    if result.returncode != 0:
        fail("could not sign the API token with ASC_KEY_P8 (is it the whole .p8 file?)")
    return f"{header}.{payload}.{b64url(der_to_raw(result.stdout))}"


def get(path, params):
    url = f"{API}/{path}?{urllib.parse.urlencode(params)}"
    request = urllib.request.Request(url, headers={"Authorization": f"Bearer {token()}"})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        try:
            details = "; ".join(e.get("detail") or e.get("title", "") for e in json.load(error).get("errors", []))
        except ValueError:
            details = ""
        hint = " (check ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_P8)" if error.code == 401 else ""
        fail(f"App Store Connect API {error.code} for {path}{hint}: {details}")


def fail(message):
    print(f"::error::{message}", flush=True)
    sys.exit(1)


def app_id(bundle_id):
    apps = get("apps", {"filter[bundleId]": bundle_id, "fields[apps]": "bundleId"}).get("data", [])
    for app in apps:
        if app["attributes"]["bundleId"] == bundle_id:
            return app["id"]
    fail(f"no App Store Connect app with bundle ID {bundle_id} (create it in App Store Connect > Apps)")


def wait_build(bundle_id, version, minutes):
    app = app_id(bundle_id)
    started = time.time()
    last = None
    while True:
        response = get("builds", {
            "filter[app]": app, "filter[version]": version, "include": "buildBetaDetail",
            "fields[builds]": "version,processingState,uploadedDate,expirationDate,buildBetaDetail",
            "fields[buildBetaDetails]": "internalBuildState",
        })
        builds = response.get("data", [])
        elapsed = int(time.time() - started)
        if builds:
            attributes = builds[0]["attributes"]
            state = attributes.get("processingState")
            beta = next((item["attributes"].get("internalBuildState") for item in response.get("included", [])
                         if item["type"] == "buildBetaDetails"), None)
            if (state, beta) != last:
                last = (state, beta)
                print(f"build {version}: {state}, internal testing {beta} ({elapsed} s)", flush=True)
            if state == "VALID":
                print(f"build {version} is processed; TestFlight until {attributes.get('expirationDate')}", flush=True)
                if beta and beta not in ("READY_FOR_BETA_TESTING", "IN_BETA_TESTING"):
                    print(f"::warning::internal testing state is {beta} (see TestFlight in App Store Connect)")
                return
            if state in ("FAILED", "INVALID"):
                fail(f"App Store Connect could not process build {version} ({state}); Apple usually emails the reason")
        elif last is None:
            last = ("not visible", None)
            print(f"build {version} is not visible yet ({elapsed} s)", flush=True)
        if elapsed > minutes * 60:
            print(f"::warning::build {version} was not processed within {minutes} minutes; "
                  "it may still appear in TestFlight later")
            return
        time.sleep(30)


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "app-id":
        print(app_id(sys.argv[2]))
    elif len(sys.argv) == 5 and sys.argv[1] == "wait-build":
        wait_build(sys.argv[2], sys.argv[3], int(sys.argv[4]))
    else:
        print(__doc__)
        sys.exit(2)


if __name__ == "__main__":
    main()
