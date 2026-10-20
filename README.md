# Broadcast (가칭)

OBS Studio의 libobs 코어를 이용한 iPadOS용 방송/녹화 앱. 개인 사용 목적이며 App Store에 배포하지 않습니다.

> Based on OBS Studio (GPLv2+). Not affiliated with or endorsed by the OBS Project.

## 기능

- 미리보기: Metal 렌더러(libobs-metal), 터치로 소스 고르기·옮기기·크기 바꾸기. 미리보기를 꺼도 송출·녹화는 계속됩니다. 계측 오버레이(fps, 렌더·GPU 시간, 지연 프레임, 메모리, 발열, 오디오, 출력 상태)
- 장면과 소스: 장면 추가·이름·순서, 소스 표시·잠금·순서·화면에 맞추기, 속성 편집. 장면 구성은 자동으로 저장하고 다시 켤 때 불러옵니다
- 입력 소스
  - 카메라: 내장 카메라와 UVC 외부 장치(캡처 카드 등), 여러 대 동시, 입력 형식·fps 선택
  - 오디오 입력: 내장 마이크와 USB 오디오 장치, 장치 전환·음소거·볼륨
  - 이미지, 이미지 슬라이드쇼, 단색
  - 텍스트: 시스템 글꼴(한국어 포함), 굵게·기울임·정렬·외곽선
  - 미디어(동영상·음악 파일): 하드웨어 디코딩(AVFoundation), 반복, 재생/일시정지·처음부터·정지
- 오디오 필터: 노이즈 억제(RNNoise), 노이즈 게이트, 컴프레서, 리미터, 익스팬더, 업워드 컴프레서, 게인, 3밴드 EQ, 극성 반전
- 출력
  - 녹화: MP4, HEVC/H.264 하드웨어 인코딩(VideoToolbox), AAC(AudioToolbox). 앱 폴더나 직접 고른 폴더(외장 SSD 등)에 저장
  - 송출: RTMP/RTMPS(H.264, HEVC는 Enhanced RTMP), SRT(MPEG-TS, 암호 지원)
  - 리플레이 버퍼: 최근 10초~5분을 메모리에 두었다가 저장 (녹화 인코더를 같이 씀)
- 진단과 로그: 앱은 libobs 로그와 앱 로그를 `Documents/broadcast.log`에 남깁니다(이전 실행은 `broadcast.log.prev`). 설정 > 진단과 로그에서 보고 공유할 수 있고, 파일 앱으로도 열 수 있습니다

## 상태

- P0~P5 완료: libobs iOS 빌드, Metal 렌더러, 카메라·오디오 입력, 녹화·송출, 본 UI, 텍스트·미디어 소스, SRT, 리플레이 버퍼. 실기기(M4 iPad Pro)에서 1080p60 녹화·송출을 확인했습니다.
- 진행 중: 사진 보관함에서 사진 가져오기, 유튜브 계정 로그인, 채팅 소스

앱 이름은 가칭("Broadcast")이고, `app/CMakeLists.txt` 맨 위에서 바꿉니다.

## Actions 아티팩트

| 이름 | 내용 |
|---|---|
| `app-ipa` | fake-signed IPA와 dSYM. LiveContainer로 설치 |
| `app-simulator-run` | 시뮬레이터에서 앱을 띄운 스크린숏(10/40/80초, 다시 켠 뒤), 앱 로그(`broadcast.log` 포함), 녹화·송출 시험 결과, 스레드 스택 |
| `libobs-ios-iphoneos` | `libobs.a`, `libobs-metal.a` 등 정적 라이브러리와 헤더 |

CI는 시뮬레이터에서 앱을 실제로 띄워 자동 시험을 돌립니다: 장면·소스 조작과 저장·불러오기, 녹화와 RTMP 송출(러너의 ffmpeg가 받음), SRT 송출, 리플레이 버퍼 저장, 미디어 소스 재생, 오디오 필터, 미리보기 끄기·켜기. 받은 파일은 ffprobe로 확인합니다.

## 구성

| 경로 | 내용 |
|---|---|
| `app/` | SwiftUI 앱. libobs 호출은 `app/Core/`의 C 브리지(`obs-core.c` 초기화·장치·통계, `scenes.c` 장면·소스·필터, `outputs.c` 녹화·송출·리플레이)에 모음 |
| `obs-studio/` | [OBS Studio](https://github.com/obsproject/obs-studio) 32.2.2 (`ba2f32b`) 소스. iPadOS용 수정은 여기서 직접 함. 원본과의 차이는 `git diff 12b487e -- obs-studio`로 확인 |
| `obs-studio/plugins/ios-audio-input/` | 오디오 입력 소스 (AVAudioSession + AVAudioEngine, 새로 작성) |
| `obs-studio/plugins/ios-text/` | 텍스트 소스 (UIKit/CoreText, 새로 작성. iOS 앱은 시스템 글꼴 파일을 읽을 수 없어 text-freetype2 대신) |
| `obs-studio/plugins/ios-media-source/` | 미디어 소스 (AVFoundation, 새로 작성) |
| `obs-studio/plugins/obs-outputs/replay-buffer.c` | iOS용 리플레이 버퍼 (OBS 것은 별도 프로세스를 띄워서 iOS에서 못 씀) |
| `obs-studio/plugins/` 의 iOS 이식 | `mac-avcapture`(카메라), `mac-videotoolbox`(인코더), `coreaudio-encoder`(AAC), `image-source`, `obs-filters`(오디오 필터, RNNoise), `obs-ffmpeg`(SRT용 MPEG-TS 출력만) |
| `ios/deps/` | 의존성 iOS arm64 크로스컴파일 스크립트: FFmpeg(이미지 디코더·MPEG-TS 먹서 등 최소 구성, nonfree 없음), mbedtls, libsrt, jansson 등 |
| `ios/scripts/` | 시뮬레이터 테스트 실행 스크립트 |
| `.github/workflows/ios.yml` | CI: 의존성 빌드 → libobs·플러그인·앱 빌드 → 시뮬레이터 단위 테스트 → 시뮬레이터에서 앱 자동 시험 → IPA |

### 정적 모듈 등록

iOS는 실행 중에 라이브러리를 불러오는 것(dlopen)이 제한되어 있어, 플러그인과 그래픽 모듈을 정적으로 링크하고 시작할 때 직접 등록합니다.

```c
extern void *libobs_metal_get_export(const char *symbol);

gs_register_static_module("libobs-metal", libobs_metal_get_export);  // obs_reset_video 전에
ovi.graphics_module = "libobs-metal";

obs_module_t *module;
obs_open_static_module(&module, &obs_static_module_<모듈 이름>, data_path);
obs_init_module(module);
```

종료 전에는 씬을 `obs_source_remove`로 캔버스에서 빼야 `obs_shutdown`이 안전하게 끝납니다.

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

GPL-2.0-or-later. 전문은 [LICENSE](LICENSE)에 있습니다. 함께 들어가는 라이브러리(FFmpeg, librtmp, Mbed TLS, SRT, RNNoise, Jansson 등)의 라이선스는 앱의 설정 > 오픈소스 라이선스에서 볼 수 있습니다.
