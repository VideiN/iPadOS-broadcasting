# Broadcast (가칭)

OBS Studio의 libobs 코어를 이용한 iPadOS용 방송/녹화 앱. 개인 사용 목적이며 App Store에 배포하지 않습니다.

> Based on OBS Studio (GPLv2+). Not affiliated with or endorsed by the OBS Project.

## 기능

- 화면: PC OBS처럼 위는 프리뷰, 아래에 장면·소스·오디오·제어 독, 오른쪽에 채팅 패널, 맨 아래 상태 줄(송출·녹화·리플레이 상태, 송출 kbps와 버린 프레임, fps, 발열). 세로나 좁은 창에서는 프리뷰 아래에 독(2×2)과 채팅을 나란히 둡니다. 돌려도 프리뷰와 열린 시트는 그대로입니다. iPad 상태 표시줄은 설정 > 화면에서 보이거나 숨기고, 보이면 그 자리는 비워 둡니다
- 미리보기: Metal 렌더러(libobs-metal), 터치로 소스 고르기·옮기기·크기 바꾸기. 미리보기를 꺼도 송출·녹화는 계속됩니다. 계측 오버레이(fps, 렌더·GPU 시간, 지연 프레임, 메모리, 발열, 오디오, 출력 상태)
- 장면과 소스: 장면 추가·이름·순서, 소스 표시·잠금·순서·화면에 맞추기, 속성 편집. 장면 구성은 자동으로 저장하고 다시 켤 때 불러옵니다
- 입력 소스
  - 카메라: 내장 카메라와 UVC 외부 장치(캡처 카드 등), 여러 대 동시, 입력 형식·fps 선택
  - 오디오 입력: 내장 마이크와 USB 오디오 장치, 장치 전환·L/R 미터·음소거·볼륨 (오디오 독. iPadOS는 입력 경로를 하나만 씁니다)
  - 이미지, 이미지 슬라이드쇼, 단색
  - 텍스트: 시스템 글꼴(한국어 포함), 굵게·기울임·정렬·외곽선
  - 미디어(동영상·음악 파일): 하드웨어 디코딩(AVFoundation), 반복, 재생/일시정지·처음부터·정지
- 오디오 필터: 노이즈 억제(RNNoise), 노이즈 게이트, 컴프레서, 리미터, 익스팬더, 업워드 컴프레서, 게인, 3밴드 EQ, 극성 반전
- 출력
  - 녹화: MP4, HEVC/H.264 하드웨어 인코딩(VideoToolbox), AAC(AudioToolbox). 앱 폴더나 직접 고른 폴더(외장 SSD 등)에 저장
  - 송출: RTMP/RTMPS(H.264, HEVC는 Enhanced RTMP), SRT(MPEG-TS, 암호 지원)
  - 리플레이 버퍼: 최근 10초~5분을 메모리에 두었다가 저장 (녹화 인코더를 같이 씀)
- YouTube 계정으로 송출: Google 로그인(OAuth, PKCE) 한 번으로 스트림 키를 자동으로 가져옵니다. "새 방송 만들기"를 고르면 제목·설명·공개 범위·지연 시간을 정해 방송을 만들고, 송출을 시작·멈추면 방송도 자동으로 시작·종료됩니다. 토큰은 Keychain에 둡니다
- 채팅
  - 채팅 소스: 로그인한 계정의 지금 방송 채팅을 방송 화면에 그립니다. 메시지 하나하나를 WebKit이 HTML과 사용자 CSS로 그려 그림으로 받습니다. 시청자가 쓴 글은 글자로만 넣고, 페이지 스크립트는 끄고, 그림은 유튜브 이모지·배지 서버에서만 불러옵니다(Content-Security-Policy). 메시지는 표시 시간(기본 3분)이 지나면 흐려지며 사라집니다(0이면 위로 밀려 나갈 때까지)
  - 채팅 패널: 오른쪽 칸에 유튜브 채팅 창을 띄웁니다(제어 독에서 보이기·숨기기). 패널 안에서 유튜브에 로그인하면 채팅도 쓰고, 패널에서 쓴 글도 채팅 소스에 나옵니다
  - 채팅 받기: 패널을 열었으면 패널 페이지가 받는 데이터를, 아니면 앱이 웹 채팅을 직접 받고, 웹 형식이 바뀌어 못 읽으면 공식 API로 넘어갑니다
- 빌드 정보: 설치한 앱이 어느 CI 실행의 빌드인지 앱 버전(`0.1.<실행 번호>`, TestFlight와 LiveContainer 목록에 보임), 계측 오버레이 첫 줄, 설정 > 정보에서 보이고, 같은 브랜치에 새 빌드가 있는지 확인할 수 있습니다
- 진단과 로그: 앱은 libobs 로그와 앱 로그를 `Documents/broadcast.log`에 남깁니다(이전 실행은 `broadcast.log.prev`). 설정 > 진단과 로그에서 보고 공유할 수 있고, 파일 앱으로도 열 수 있습니다

## 상태

- P0~P5 완료: libobs iOS 빌드, Metal 렌더러, 카메라·오디오 입력, 녹화·송출, 본 UI, 텍스트·미디어 소스, SRT, 리플레이 버퍼. 실기기(M4 iPad Pro)에서 1080p60 녹화·송출을 확인했습니다. 충전하지 않고 1시간 48분 송출하는 동안 발열 상태는 내내 정상이었습니다.
- 유튜브 계정 로그인과 채팅 소스·채팅 패널: 실기기에서 로그인 송출과 채팅 소스를 확인했습니다. 패널에서 로그인하면 유튜브 앱이 열리던 문제, 송출 중에 연 패널이 빈 채로 남던 문제의 수정과 메시지 표시 시간은 실기기 확인 전입니다.
- PC OBS 같은 화면 배치, 오디오 독, 상태 표시줄 설정: 시뮬레이터 시험을 통과했고 실기기 확인 전입니다.
- TestFlight 배포: CI가 정식 서명해 App Store Connect에 올리는 것까지 확인했습니다. TestFlight에서 받아 설치하는 것은 확인 중입니다.
- 진행 중: 사진 보관함에서 사진 가져오기, 아이폰 얼굴 추적으로 움직이는 아바타

앱 이름은 가칭("Broadcast")이고, `app/CMakeLists.txt` 맨 위에서 바꿉니다.

## YouTube 로그인용 OAuth 클라이언트

로그인에는 Google Cloud 프로젝트의 **iOS 유형** OAuth 클라이언트 ID(`…apps.googleusercontent.com`, 비밀값 없음)와 그 프로젝트의 YouTube Data API v3가 필요합니다. 이 저장소의 코드에는 클라이언트 ID가 없습니다.

- 기기용 빌드에 넣기: CMake에 `-DAPP_YOUTUBE_CLIENT_ID=<클라이언트 ID>`를 넘깁니다. CI는 저장소 비밀값 `YOUTUBE_CLIENT_ID`가 있으면 iphoneos 빌드에만 넘깁니다(로그에는 가려지고, 포크의 PR에는 넘어가지 않음)
- 빌드에 없으면 앱의 설정 > 송출 > 방식 > YouTube 계정에서 직접 입력합니다

포크해서 쓸 때는 자기 Google Cloud 프로젝트에서 클라이언트를 만드세요.

## TestFlight로 설치

Apple 개발자 계정이 있으면 CI가 기기용 빌드를 정식 서명해 App Store Connect에 올리고, iPad의 TestFlight 앱으로 설치합니다 (맥이 없어도 됩니다). 내부 테스터는 심사 없이 받고, 한 빌드는 90일 동안 쓸 수 있습니다.

- 언제 올리나: main에 푸시할 때, 그리고 Actions에서 수동 실행할 때 "TestFlight에 올리기"를 고르면. PR에서는 올리지 않습니다
- 하는 일(`ios/scripts/testflight.sh`): 가짜 서명 IPA를 받아 프로필이 App Store용이고 이 앱의 App ID이며 그 인증서로 만든 것인지 확인한 뒤, 이 실행만 쓰는 키체인으로 다시 서명해 `altool`로 올립니다. 다음 작업이 App Store Connect API(`ios/scripts/asc.py`)로 처리 완료를 기다립니다
- 서명된 IPA는 아티팩트로 남기지 않고, 인증서 이름(계정 주인 이름)은 로그에 찍지 않습니다
- 비밀값: 저장소 Settings > Environments에 `testflight` 환경을 만들고(배포 브랜치는 main 등 올릴 브랜치만), 그 환경에 넣습니다. 비밀값이 하나도 없으면 올리지 않고 넘어갑니다

| 이름 | 내용 |
|---|---|
| `APPLE_DIST_P12_BASE64`, `APPLE_DIST_P12_PASSWORD` | Apple Distribution 인증서와 개인 키(.p12, base64)와 그 비밀번호. CSR은 맥 없이 `openssl`로 만들 수 있습니다 |
| `APPLE_PROFILE_BASE64` | 이 앱 App ID(`io.github.videin.broadcast`, Increased Memory Limit 켬)의 App Store 배포 프로필(base64) |
| `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` | App Store Connect API 키 (.p8 파일 내용) |

포크해서 쓸 때는 `app/CMakeLists.txt`의 번들 ID를 자기 것으로 바꾸고 자기 계정의 App ID·인증서·프로필·API 키를 쓰세요.

## Actions 아티팩트

| 이름 | 내용 |
|---|---|
| `app-ipa-<실행 번호>` | fake-signed IPA(`Broadcast-<실행 번호>-<브랜치>-<커밋>.ipa`)와 dSYM. LiveContainer로 설치. 실행 요약에 빌드 번호·커밋·YouTube 클라이언트 ID가 들어갔는지가 나옵니다 |
| `app-simulator-run` | 시뮬레이터에서 앱을 띄운 스크린숏(가로·세로, 다시 켠 뒤), 앱 로그(`broadcast.log` 포함), 녹화·송출 시험 결과, 가짜 YouTube 서버 로그, 스레드 스택 |
| `libobs-ios-iphoneos` | `libobs.a`, `libobs-metal.a` 등 정적 라이브러리와 헤더 |

CI는 시뮬레이터에서 앱을 실제로 띄워 자동 시험을 돌립니다: 장면·소스 조작과 저장·불러오기, 녹화와 RTMP 송출(러너의 ffmpeg가 받음), SRT 송출, 리플레이 버퍼 저장, 미디어 소스 재생, 오디오 필터, 미리보기 끄기·켜기, 화면 돌리기. 받은 파일은 ffprobe로 확인합니다.

YouTube 로그인과 채팅은 가짜 Google·YouTube 서버(`ios/scripts/youtube-mock.py`)로 시험합니다: 로그인(PKCE), 만료된 토큰 갱신, 서버 오류 뒤 재시도, 스트림·방송 만들기와 연결, 받은 주소로 실제 송출, 채팅 받기(패널 페이지·직접·공식 API)와 지운 메시지, 패널에서 쓴 글, 채팅 탭을 열었을 때 패널이 화면에 붙는지. 채팅 소스의 메시지가 표시 시간 뒤에 사라지는지도 봅니다. 채팅 소스에는 마크업·스크립트·외부 그림 주소를 섞은 메시지를 넣어 글자로만 그려지는지, 함정 서버로 요청이 가지 않는지 확인합니다.

## 구성

| 경로 | 내용 |
|---|---|
| `app/` | SwiftUI 앱. libobs 호출은 `app/Core/`의 C 브리지(`obs-core.c` 초기화·장치·통계, `scenes.c` 장면·소스·필터, `outputs.c` 녹화·송출·리플레이)에 모음 |
| `obs-studio/` | [OBS Studio](https://github.com/obsproject/obs-studio) 32.2.2 (`ba2f32b`) 소스. iPadOS용 수정은 여기서 직접 함. 원본과의 차이는 `git diff 12b487e -- obs-studio`로 확인 |
| `obs-studio/plugins/ios-audio-input/` | 오디오 입력 소스 (AVAudioSession + AVAudioEngine, 새로 작성) |
| `obs-studio/plugins/ios-text/` | 텍스트 소스 (UIKit/CoreText, 새로 작성. iOS 앱은 시스템 글꼴 파일을 읽을 수 없어 text-freetype2 대신) |
| `obs-studio/plugins/ios-media-source/` | 미디어 소스 (AVFoundation, 새로 작성) |
| `obs-studio/plugins/ios-chat/` | 채팅 소스 (메시지를 WebKit으로 그려 텍스처로, 기본 CSS는 `data/default.css`, 새로 작성). 채팅 받기와 YouTube 로그인은 앱의 `Chat.swift`·`YouTube.swift` |
| `obs-studio/plugins/obs-outputs/replay-buffer.c` | iOS용 리플레이 버퍼 (OBS 것은 별도 프로세스를 띄워서 iOS에서 못 씀) |
| `obs-studio/plugins/` 의 iOS 이식 | `mac-avcapture`(카메라), `mac-videotoolbox`(인코더), `coreaudio-encoder`(AAC), `image-source`, `obs-filters`(오디오 필터, RNNoise), `obs-ffmpeg`(SRT용 MPEG-TS 출력만) |
| `ios/deps/` | 의존성 iOS arm64 크로스컴파일 스크립트: FFmpeg(이미지 디코더·MPEG-TS 먹서 등 최소 구성, nonfree 없음), mbedtls, libsrt, jansson 등 |
| `ios/scripts/` | 시뮬레이터 테스트 실행 스크립트, CI용 가짜 Google·YouTube 서버, TestFlight 서명·업로드(`testflight.sh`, `asc.py`) |
| `.github/workflows/ios.yml` | CI: 의존성 빌드 → libobs·플러그인·앱 빌드 → 시뮬레이터 단위 테스트 → 시뮬레이터에서 앱 자동 시험 → IPA → (main·수동) TestFlight 업로드와 처리 확인 |
| `app/Resources/Assets.xcassets` | 앱 아이콘 (임시, `app/Resources/make-app-icon.py`로 만듦) |

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

- TestFlight: 위의 "TestFlight로 설치". App Store Connect에서 내부 테스트 그룹에 자기 계정을 넣어 두면 새 빌드가 TestFlight 앱에 나타납니다
- LiveContainer: Actions 아티팩트 `app-ipa-<실행 번호>`의 IPA는 fake-signed(ad-hoc) 빌드라 그대로는 설치할 수 없습니다. LiveContainer 등으로 재서명해서 실행하세요. 두 방식은 저장 공간이 따로라 장면 구성·설정·로그인을 따로 합니다

## 라이선스

GPL-2.0-or-later. 전문은 [LICENSE](LICENSE)에 있습니다. 함께 들어가는 라이브러리(FFmpeg, librtmp, Mbed TLS, SRT, RNNoise, Jansson 등)의 라이선스는 앱의 설정 > 오픈소스 라이선스에서 볼 수 있습니다.
