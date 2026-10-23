# Face Link: 아이폰 얼굴 추적 → Broadcast 아바타

설계 초안 v1 (2026-10-23). 두 저장소가 함께 보는 문서다: 아이폰 컴패니언 앱(새 저장소)과 Broadcast(이 저장소의 `face-link` 브랜치).

이 문서는 MIT License로 둔다. 컴패니언 저장소에 그대로 옮겨도 된다 (Broadcast 저장소의 나머지는 GPL).

## 1. 무엇을 만드나

아이폰이 얼굴을 추적해 **수치만** 보내고(영상은 보내지 않는다), 아이패드의 Broadcast가 받아 아바타를 그려 방송 캔버스에 넣는다.

```
아이폰 컴패니언 앱 (새 저장소)              Broadcast (iPad, 이 저장소)
ARKit 얼굴 추적 (TrueDepth)                 얼굴 데이터 공급원
 블렌드셰이프 52개 + 머리·눈 자세             ├ 네트워크: 아이폰 (주)  ◀── UDP, FaceLink v1
 정면 보정, 60/30Hz                          └ 이 아이패드의 내장 카메라 (선택)
        │                                            │ 같은 값 (FaceFrame)
        └──────── UDP / OSC (VMC 호환) ──────▶  아바타 소스 (OBS 소스) → 캔버스
```

- 사용 환경: 아이패드가 얼굴 정면에 있는 일이 드물다. 그래서 위치를 자유롭게 둘 수 있는 **아이폰이 주 추적 장치**이고, 아이패드 내장 카메라는 선택이다
- 아이폰을 비스듬히 둬도 아바타는 정면을 봐야 한다 → **정면 보정**(3.2)이 중요하다

## 2. 역할과 저장소

| 구성 | 저장소 | 라이선스 |
|---|---|---|
| 컴패니언 앱 (iPhone, 보내는 쪽) | 새 **공개** 저장소 (다른 에이전트가 맡음) | **MIT** (2026-10-24 결정) |
| 수신·아바타 소스 (iPad, 받는 쪽) | 이 저장소, `face-link` 브랜치 | GPL (OBS를 포함하므로) |

- 두 앱은 **이 문서의 프로토콜로만** 연결된다. 서로의 코드를 복사하지 않는다. 특히 Broadcast의 GPL 코드를 컴패니언 앱에 가져오지 않는다 (네트워크 프로토콜로만 통신하는 별개 프로그램이어야 컴패니언 앱의 라이선스를 자유롭게 고를 수 있다)
- 프로토콜을 바꾸면 버전(`/FaceLink/Hello`의 첫 인자)을 올리고 두 저장소의 이 문서를 함께 고친다
- 받는 쪽은 기존 VMC 앱(예: Waidayo)도 받을 수 있게 VMC 프로토콜과 호환되게 한다. 컴패니언 앱도 VMC를 받는 PC 프로그램(VSeeFace 등)에 그대로 보낼 수 있다

## 3. 프로토콜: FaceLink v1

[VMC 프로토콜](https://protocol.vmc.info/english)(MIT) 위에 작은 확장(`/FaceLink/…`)을 얹는다. VMC 규칙대로 받는 쪽은 모르는 주소와 남는 인자를 무시하므로, 다른 VMC 앱과 섞여도 깨지지 않는다.

### 3.1 전송

- UDP/IP. 메시지는 OSC 1.0 (빅 엔디언, 4바이트 정렬). 타입은 `s`(문자열), `f`(float32), `i`(int32)만 쓴다
- 방향: 아이폰(보내는 쪽, VMC의 Performer) → 아이패드(받는 쪽, Marionette). 거꾸로는 3.5의 Ack와 명령만
- 받는 쪽 기본 포트 **39539** (VMC와 같음). 둘 다 설정에서 바꿀 수 있게
- 속도: 기본 60Hz (ARKit 프레임마다), 설정으로 30Hz
- 한 프레임은 OSC 번들 하나 이상으로 보낸다. 번들의 time tag는 "즉시"(1). UDP 데이터그램 하나는 **1,400바이트 이하**로 나눈다 (블렌드셰이프 52개를 한 번들에 넣으면 약 2.5KB라 IP 조각이 생긴다)
- 한 프레임의 순서: `/FaceLink/Frame` → `/VMC/Ext/Bone/Pos`(머리, 눈) → `/VMC/Ext/Blend/Val` × 52 → `/VMC/Ext/Blend/Apply`. 받는 쪽은 `Apply`를 만나면 그때까지 모인 값을 한 프레임으로 적용한다

### 3.2 VMC 호환 메시지

| 주소 | 인자 | 뜻 |
|---|---|---|
| `/VMC/Ext/Blend/Val` | `s` 이름, `f` 값 (0~1) | 블렌드셰이프 하나. 이름은 부록 A |
| `/VMC/Ext/Blend/Apply` | 없음 | 이 프레임의 Val을 한꺼번에 적용 |
| `/VMC/Ext/Bone/Pos` | `s` "Head", `f` px py pz, `f` qx qy qz qw | 머리 자세 |
| `/VMC/Ext/Bone/Pos` | `s` "LeftEye" 또는 "RightEye", `f` 0 0 0, `f` qx qy qz qw | 눈 방향 (보내기 선택) |

- **좌표계**: VMC(Unity) 기준. 왼손 좌표계, +Y 위, +Z 앞, 단위 미터. ARKit(오른손 좌표계)에서 바꿀 때는 위치 (x, y, −z), 회전 쿼터니언 (−qx, −qy, qz, qw)
- **머리 자세는 카메라 기준**이다: `camera.transform⁻¹ × faceAnchor.transform`. 그리고 **정면 보정 뒤의 값**을 보낸다: 사용자가 정면을 본다고 누른 순간의 자세를 기준(회전 0, 위치 0)으로 삼아 그 차이만 보낸다. 아이폰을 옆에 비스듬히 둬도 정면을 보면 회전이 0이 된다
- 위치는 기준에서 움직인 거리(미터). 받는 쪽은 회전만 써도 된다
- **거울**: 보내는 쪽은 ARKit 그대로, 사용자 기준 값을 보낸다 (`EyeBlinkLeft` = 사용자의 왼쪽 눈). 거울처럼 보이게 좌우를 바꾸는 것은 받는 쪽 설정이다 (Left↔Right 이름 교환, 머리 yaw·roll 부호 반전)
- 블렌드셰이프 이름은 ARKit 52개를 대문자로 시작하게 쓴 "Perfect Sync" 표기다 (`EyeBlinkLeft`, `JawOpen` …). 받는 쪽은 대소문자를 무시하고, ARKit 원래 문자열(`eyeBlink_L` 등)도 받아 준다

### 3.3 FaceLink 확장 (보내는 쪽 → 받는 쪽)

| 주소 | 인자 | 언제 |
|---|---|---|
| `/FaceLink/Hello` | `s` 프로토콜 버전 "1", `s` 기기 이름, `s` 앱 버전, `s` 세션 ID, `s` 페어링 토큰 (없으면 "") | 보내는 동안 1초마다 |
| `/FaceLink/Frame` | `i` 순번, `f` 보낸 시각 (세션 시작부터 초), `i` 추적 상태 (1 얼굴 있음, 0 놓침) | 프레임마다 맨 앞 |

- 세션 ID는 앱이 보내기를 시작할 때마다 새로 만든다 (UUID 문자열)
- 순번은 세션 안에서 1씩 늘린다 (2³¹−1 다음은 0). 받는 쪽은 같은 세션에서 마지막보다 작거나 같은 순번의 프레임을 버린다. 세션 ID가 바뀌면 처음부터 받는다
- 추적 상태가 0이면 그 프레임의 Bone·Val은 빼도 된다. 받는 쪽은 놓친 지 0.5초가 넘으면 아바타를 천천히 중립으로 돌린다

### 3.4 찾기와 연결

- **Bonjour**: 받는 쪽(아이패드)이 `_facelink._udp`로 알린다. TXT: `v=1`, `name=<아이패드 이름>`. 보내는 쪽은 목록에서 고른다
- **QR / 직접 입력**: 받는 쪽은 `facelink://<IP>:<포트>?v=1&name=<이름>&token=<토큰>` QR을 보여 준다. 보내는 쪽은 찍거나 `IP:포트`를 직접 넣는다
- 두 앱 모두 LiveContainer로 설치할 수 있다. 그 안에서는 Bonjour 알림·찾기와 로컬 네트워크 권한이 호스트 앱의 Info.plist를 따를 수 있어 막힐 수 있다(실기기에서 확인 전). 그래서 QR·직접 입력은 반드시 둔다
- Info.plist: 두 앱 모두 `NSLocalNetworkUsageDescription`, `NSBonjourServices` = [`_facelink._udp`]. 아이폰 앱은 `NSCameraUsageDescription`(ARKit)
- 보내는 쪽은 마지막으로 연결한 대상을 기억한다

### 3.5 받는 쪽 → 보내는 쪽 (선택이지만 v1에 넣는다)

받는 쪽은 프레임이 온 출발 주소·포트로 보낸다.

| 주소 | 인자 | 언제 |
|---|---|---|
| `/FaceLink/Ack` | `i` 마지막으로 받은 순번, `f` 받는 쪽에서 센 초당 프레임, `s` 받는 쪽 이름 | 1초마다 |
| `/FaceLink/Calibrate` | 없음 | 아이패드에서 "정면 맞추기"를 누를 때. 아이폰은 지금 자세를 새 기준으로 삼는다 |

- 보내는 쪽은 Ack가 3초 넘게 없으면 "응답 없음"으로 보이되 보내기는 계속한다
- 지연은 보내는 쪽이 Ack의 순번과 자기가 그 순번을 보낸 시각으로 대략 계산해 보여 줄 수 있다

### 3.6 페어링과 안전

- 같은 Wi-Fi 안에서만 쓴다. 암호화는 없다 (얼굴 수치뿐, 영상·소리는 보내지 않는다)
- 받는 쪽은 한 번에 보내는 쪽 하나만 쓴다: 토큰이 맞는 `/FaceLink/Hello`를 보낸 첫 주소. 토큰은 QR에 들어 있다
- Hello 없이 오는 VMC(Waidayo 같은 다른 앱)는 받는 쪽 설정 "다른 VMC 앱 받기"를 켰을 때만 쓴다
- 받는 쪽은 64KB가 넘거나 OSC로 읽을 수 없는 패킷을 버리고, 블렌드셰이프 값은 0~1로, 쿼터니언은 정규화해 쓴다. 이름은 부록 A에 있는 것만 쓴다

### 3.7 끊김과 흔들림

- 받는 쪽은 최근 프레임으로 그리되 짧게 보간해(예: 2프레임) 네트워크 흔들림을 줄인다
- 1초 넘게 프레임이 없으면 "연결 끊김"으로 보이고 아바타는 중립으로 돌아간다

## 4. 컴패니언 앱(iPhone) 계획: 다른 에이전트에게

### 4.1 v1 범위

- ARKit `ARFaceTrackingConfiguration` (TrueDepth 카메라가 있는 아이폰, Face ID 기종). `ARFaceAnchor.blendShapes` 52개, 머리 자세, `leftEyeTransform`·`rightEyeTransform`
- **정면 보정** 버튼 (+ 받는 쪽의 `/FaceLink/Calibrate`)
- 보낼 곳 고르기: Bonjour 목록 / QR 찍기 / IP:포트 직접 입력
- 상태: 추적 중·놓침, 보내는 fps, Ack(연결됨, 받는 쪽 fps, 대략 지연)
- 설정: 60/30Hz, 눈 보내기, 머리 위치 보내기, 포트, 기기 이름
- 화면: 확인용 작은 카메라 미리보기와 **어둡게 모드**(검은 화면, 발열·배터리 줄이기), 화면 자동 잠금 끔
- 앱이 백그라운드로 가면 ARKit이 멈춘다 → 앞에 켜 둬야 한다고 안내
- **시험 송신 모드**: 얼굴 없이 합성 값(눈 깜빡임, 입 벌림, 머리 좌우)을 보낸다. 시뮬레이터에서는 ARKit 얼굴 추적이 안 되므로 CI 시험에 쓴다

### 4.2 기술 메모

- Swift, SwiftUI, ARKit, Network.framework(`NWConnection` UDP, `NWBrowser`), QR은 VisionKit `DataScannerViewController` 또는 AVFoundation
- OSC 인코더는 직접 작게 만든다 (외부 의존 없이 Apple 프레임워크만)
- ARKit 얼굴 추적을 오래 돌리면 발열이 있다 → 30Hz와 어둡게 모드
- 최소 iOS 버전은 사용자 아이폰에 맞춰 정한다

### 4.3 빌드와 배포

- 사용자는 Windows만 쓰고 Mac이 없다 → **모든 빌드는 GitHub Actions macOS 러너**에서
- 서명 없는(가짜 서명) IPA를 아티팩트로 만들어 LiveContainer 등으로 설치한다. Broadcast 저장소의 `.github/workflows/ios.yml`이 IPA를 만드는 방식을 참고하되, 코드는 새로 쓴다
- **앱 버전에 CI 실행 번호를 넣어** 설치한 앱이 어느 빌드인지 기기에서 바로 보이게 한다 (Broadcast에서 다른 빌드를 깔고도 몰랐던 일이 있었다)
- CI 시험: 시뮬레이터에서 시험 송신 모드로 띄우고, 파이썬 수신기로 받아 형식을 확인한다 (Hello, Frame 순번 증가, 이름 52개, Apply, 데이터그램 1,400바이트 이하)

### 4.4 라이선스

- 공개 저장소, MIT License (2026-10-24 결정). 저장소 맨 위에 LICENSE 파일을 둔다. Broadcast의 코드는 가져오지 않는다. 의존성은 Apple 프레임워크만
- Live2D 같은 독점 SDK는 넣지 않는다. 아바타 형식은 VRM으로 정했다 (아바타를 그리는 것은 아이패드 쪽이고, 컴패니언 앱은 수치만 보낸다)

### 4.5 사용자와 일하는 방식

- 사용자는 한국어로 소통한다. 앱 화면 문구도 한국어
- 커밋·문서 규칙 등은 사용자와 정한다

## 5. Broadcast(iPad) 쪽 계획: 이 저장소 `face-link` 브랜치

1. **수신기**: `NWListener` UDP 39539, OSC 해석, 최신 프레임 저장(스레드 안전), Bonjour 알림, QR 화면, Ack·Calibrate. 설정 › 얼굴 추적: 포트, 토큰 다시 만들기, "다른 VMC 앱 받기", 상태(보내는 쪽 이름, fps, 추적 상태, 값 미리보기)
2. **시험**: `ios/scripts/facelink-sender.py`(합성 값을 v1로 보냄)로 CI에서 받기를 확인. 컴패니언 앱보다 먼저 만들어 두 쪽이 같은 시험 도구를 쓴다
3. **얼굴 데이터 공급원**: 네트워크(아이폰)와 이 아이패드 내장 카메라를 같은 `FaceFrame`으로. 아바타는 공급원을 모른다
4. **아이패드 내장 카메라**: 먼저 실기기 실험. ARKit 얼굴 추적을 켜면 다른 카메라 소스(UVC 캡처카드, 후면 카메라가 함께 쓰는 멀티캠 세션)가 끊기는지 본다
   - 전면 카메라만 부딪히면: ARKit을 쓰고, 켤 때 **전면 카메라를 쓰는 카메라 소스를 자동으로 끈다** (그 소스에 "얼굴 추적이 전면 카메라 사용 중" 표시, 속성에서 전면 카메라를 못 고르게, 끄면 되돌림, 송출·녹화 중 그 소스가 보이면 먼저 확인)
   - 다른 카메라도 끊기면: ARKit을 쓰지 않고, 우리 캡처가 이미 받는 전면 카메라 프레임에 Vision(의존 없음, 덜 정밀) 또는 MediaPipe Face Landmarker(ARKit식 52개 값, Apache-2.0)를 돌린다
5. **아바타 소스**(OBS 소스): 아바타 형식은 **VRM**으로 정했다 (2026-10-24). 5.1 참고

### 5.1 VRM 아바타 소스

- **그리기**: [VRMKit](https://github.com/tattn/VRMKit) 0.11 (MIT)의 RealityKit 렌더러로 모델을 읽고, RealityKit의 [`RealityRenderer`](https://developer.apple.com/documentation/realitykit/realityrenderer)(iOS 18 이상)로 화면 밖 텍스처에 그린다. 그 텍스처는 IOSurface로 만들어(`.renderTarget`·`.shaderRead`) libobs에 `gs_texture_create_from_iosurface`·`gs_texture_rebind_iosurface`로 넘긴다 (libobs-metal에 있음). 두 장을 번갈아 써서 그리는 중인 것을 방송에 내보내지 않는다. 배경은 투명
- **최소 iOS**: VRMKit의 RealityKit 렌더러가 iOS 18 이상이라, 앱의 최소 버전을 17.0 → 18.0으로 올리거나 아바타 소스만 iOS 18 이상에서 쓰게 한다 (사용자 기기는 iPadOS 27)
- **VRMKit 넣기**: 이 앱은 CMake로 빌드하므로 VRMKit 소스를 저장소에 넣고(MIT 고지와 함께, 라이선스 목록에도) 별도 Swift 모듈로 묶는다 (VRMKit은 Swift 6, 앱은 Swift 5 모드)
- **VRM 0.x와 1.0** 모두 읽는다 (VRMKit이 지원). 머리카락·옷 흔들림(스프링 본)도 VRMKit이 한다
- **얼굴 수치 → 모델**
  - 퍼펙트 싱크 모델(ARKit 52개 이름의 표정을 가진 모델): 받은 이름 그대로 사용자 정의 표정에 넣는다
  - 일반 모델: VRM 기본 표정으로 맞춘다. 눈 깜빡임(왼·오른) ← EyeBlink, 입 모양 아·이·우·에·오 ← JawOpen·MouthFunnel·MouthPucker·MouthStretch 등의 조합, 웃음 ← MouthSmile, 시선 ← 눈 회전 또는 EyeLook 값
  - 머리: Head 본 회전 (일부를 목에 나눠 자연스럽게). 머리 위치는 쓰지 않거나 약하게
- **속성**(초안): 모델 파일(파일 앱·사진에서 가져와 Documents/Media에), 얼굴 데이터 공급원, 구도(얼굴·상반신·전신, 확대), 거울, "정면 맞추기", 표정 세기, 모델의 사용 조건(VRM 메타데이터의 아바타 사용·재배포 허락 등)을 보여 주기
- **CI 시험 모델**: 재배포가 허락된(CC0 등) VRM을 저장소에 넣는다. VRoid의 초기 샘플 일부가 CC0로 공개되어 있다고 알려져 있으니, 파일에 든 라이선스 정보로 확인한 뒤 고른다. 합성 송신기로 움직여 스크린숏으로 확인

## 부록 A. 블렌드셰이프 이름 (52개)

보내는 이름 = ARKit `ARFaceAnchor.BlendShapeLocation`의 Swift 이름을 대문자로 시작하게. 괄호는 ARKit 원래 문자열.

| 부위 | 이름 |
|---|---|
| 왼눈 | EyeBlinkLeft (eyeBlink_L), EyeLookDownLeft (eyeLookDown_L), EyeLookInLeft (eyeLookIn_L), EyeLookOutLeft (eyeLookOut_L), EyeLookUpLeft (eyeLookUp_L), EyeSquintLeft (eyeSquint_L), EyeWideLeft (eyeWide_L) |
| 오른눈 | EyeBlinkRight (eyeBlink_R), EyeLookDownRight (eyeLookDown_R), EyeLookInRight (eyeLookIn_R), EyeLookOutRight (eyeLookOut_R), EyeLookUpRight (eyeLookUp_R), EyeSquintRight (eyeSquint_R), EyeWideRight (eyeWide_R) |
| 턱 | JawForward (jawForward), JawLeft (jawLeft), JawRight (jawRight), JawOpen (jawOpen) |
| 입 | MouthClose (mouthClose), MouthFunnel (mouthFunnel), MouthPucker (mouthPucker), MouthLeft (mouthLeft), MouthRight (mouthRight), MouthSmileLeft (mouthSmile_L), MouthSmileRight (mouthSmile_R), MouthFrownLeft (mouthFrown_L), MouthFrownRight (mouthFrown_R), MouthDimpleLeft (mouthDimple_L), MouthDimpleRight (mouthDimple_R), MouthStretchLeft (mouthStretch_L), MouthStretchRight (mouthStretch_R), MouthRollLower (mouthRollLower), MouthRollUpper (mouthRollUpper), MouthShrugLower (mouthShrugLower), MouthShrugUpper (mouthShrugUpper), MouthPressLeft (mouthPress_L), MouthPressRight (mouthPress_R), MouthLowerDownLeft (mouthLowerDown_L), MouthLowerDownRight (mouthLowerDown_R), MouthUpperUpLeft (mouthUpperUp_L), MouthUpperUpRight (mouthUpperUp_R) |
| 눈썹 | BrowDownLeft (browDown_L), BrowDownRight (browDown_R), BrowInnerUp (browInnerUp), BrowOuterUpLeft (browOuterUp_L), BrowOuterUpRight (browOuterUp_R) |
| 볼·코 | CheekPuff (cheekPuff), CheekSquintLeft (cheekSquint_L), CheekSquintRight (cheekSquint_R), NoseSneerLeft (noseSneer_L), NoseSneerRight (noseSneer_R) |
| 혀 | TongueOut (tongueOut) |

## 부록 B. 한 프레임의 예

```
번들 1 (time tag 1 = 즉시, 1,400바이트 이하)
  /FaceLink/Frame        ,ifi   1234  532.016  1
  /VMC/Ext/Bone/Pos      ,sfffffff  "Head"  0.01 -0.02 0.00  0.02 0.10 0.01 0.99
  /VMC/Ext/Blend/Val     ,sf    "EyeBlinkLeft"   0.03
  /VMC/Ext/Blend/Val     ,sf    "EyeBlinkRight"  0.04
  … (번들이 1,400바이트에 가까워지면 끊는다)
번들 2
  /VMC/Ext/Blend/Val     ,sf    "MouthSmileLeft" 0.20
  … (나머지)
  /VMC/Ext/Blend/Apply   ,
```

1초마다 따로: `/FaceLink/Hello ,sssss "1" "내 iPhone" "0.1.12" "6F1C…" "k3x9…"`
