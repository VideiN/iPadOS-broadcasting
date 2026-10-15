# (앱 이름 미정)

OBS Studio의 libobs 코어를 이용한 iPadOS용 방송/녹화 앱. 개인 사용 목적이며 App Store에 배포하지 않습니다.

> Based on OBS Studio (GPLv2+). Not affiliated with or endorsed by the OBS Project.

## 상태

- P0 완료: CI에서 libobs를 iOS용 정적 라이브러리(`libobs.a`)로 빌드하고, iPad 시뮬레이터에서 단위 테스트를 돌립니다.
- P1 진행 중: Metal 렌더러(libobs-metal)를 iOS로 이식했고, 시뮬레이터에서 렌더링 결과를 확인합니다. 남은 일은 최소 앱과 실기기 확인입니다.

빌드 결과(`libobs.a`, `libobs-metal.a` 등과 헤더)는 Actions 실행의 `libobs-ios-iphoneos` 아티팩트로 받을 수 있습니다.

### 앱에서 쓰는 방법

플러그인과 그래픽 모듈은 정적으로 링크하고, 시작할 때 직접 등록합니다.

```c
extern void *libobs_metal_get_export(const char *symbol);

gs_register_static_module("libobs-metal", libobs_metal_get_export);  // obs_reset_video 전에
ovi.graphics_module = "libobs-metal";

obs_module_t *module;
obs_open_static_module(&module, &obs_static_module_<모듈 이름>, data_path);
obs_init_module(module);
```

종료 전에는 씬을 `obs_source_remove`로 캔버스에서 빼야 `obs_shutdown`이 안전하게 끝납니다.

## 구성

| 경로 | 내용 |
|---|---|
| `obs-studio/` | [OBS Studio](https://github.com/obsproject/obs-studio) 32.2.2 (`ba2f32b`) 소스. iPadOS용 수정은 여기서 직접 함. 원본과의 차이는 `git diff 12b487e -- obs-studio`로 확인 |
| `ios/deps/` | 의존성(FFmpeg, jansson 등) iOS arm64 크로스컴파일 스크립트 |
| `ios/scripts/` | 시뮬레이터 테스트 실행 스크립트 |
| `.github/workflows/ios.yml` | CI: 의존성 빌드 → libobs·libobs-metal 정적 빌드 → 시뮬레이터 테스트 |

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
