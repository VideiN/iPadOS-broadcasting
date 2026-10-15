# (앱 이름 미정)

OBS Studio의 libobs 코어를 이용한 iPadOS용 방송/녹화 앱. 개인 사용 목적이며 App Store에 배포하지 않습니다.

> Based on OBS Studio (GPLv2+). Not affiliated with or endorsed by the OBS Project.

## 상태

P0 진행 중: libobs를 iOS용 정적 라이브러리로 빌드하고 시뮬레이터에서 테스트합니다.

## 구성

| 경로 | 내용 |
|---|---|
| `obs-studio/` | [OBS Studio](https://github.com/obsproject/obs-studio) 32.2.2 (`ba2f32b`) 소스. iPadOS용 수정은 여기서 직접 함. 원본과의 차이는 `git diff 12b487e -- obs-studio`로 확인 |
| `ios/deps/` | 의존성(FFmpeg, jansson 등) iOS arm64 크로스컴파일 스크립트 |
| `ios/scripts/` | 시뮬레이터 테스트 실행 스크립트 |
| `.github/workflows/ios.yml` | CI: 의존성 빌드 → libobs 정적 빌드 → 시뮬레이터 테스트 |

## 빌드 (macOS)

```sh
bash ios/deps/build-deps.sh iphoneos          # .deps/ios-iphoneos
cmake -S obs-studio -B build_ios -G Ninja \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT="$(xcrun --sdk iphoneos --show-sdk-path)" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
  -DCMAKE_PREFIX_PATH="$PWD/.deps/ios-iphoneos" \
  -DOBS_VERSION_OVERRIDE=32.2.2
cmake --build build_ios
```

시뮬레이터 테스트까지 하려면 `iphonesimulator`로 바꾸고 `-DENABLE_UNIT_TESTS=ON`과 `-DCMAKE_CROSSCOMPILING_EMULATOR="/bin/bash;$PWD/ios/scripts/sim-run.sh"`를 더한 뒤, 부팅한 시뮬레이터의 UDID를 `SIM_UDID`로 넘겨 `ctest`를 실행합니다.

## 설치

Release에 올라가는 IPA는 fake-signed(ad-hoc) 빌드라 그대로 설치할 수 없습니다. LiveContainer 등으로 재서명해서 실행하세요.

## 라이선스

GPL-2.0-or-later. 전문은 [LICENSE](LICENSE)에 있습니다.
