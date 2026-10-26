# Xcode Cloud로 main 배포 (P12)

main에 푸시하면 이렇게 흘러간다.

1. GitHub Actions가 평소처럼 CMake로 빌드하고 시뮬레이터에서 시험한다.
   - 기기용 빌드는 libobs·플러그인·의존성을 **iOS SDK 묶음**(정적 라이브러리, `ios/scripts/ios-sdk.py package`)으로 만든다.
   - 같은 소스로 처음 만든 묶음이면 Release `ios-sdk-<열쇠>`에 올린다. 열쇠는 obs-studio·ios/deps 등의 git 트리 해시다.
2. `Xcode project` 작업이 그 묶음으로 XcodeGen 프로젝트(`xcode/project.yml`)를 서명 없이 빌드해 본다.
3. main이면 `Xcode Cloud (main)` 작업이 두 가지를 한다.
   - 이 실행의 번호를 Release `xcode-cloud-main`의 `main-build.json`에 남긴다.
   - App Store Connect API로 Xcode Cloud 워크플로를 시작한다 (`ios/scripts/asc.py xcode-cloud-start`).
4. Xcode Cloud가 같은 커밋을 받는다.
   - `xcode/ci_scripts/ci_post_clone.sh`가 실행된다. 이 스크립트(`ios/xcode/bootstrap.sh`)는 SDK 묶음을 받고, VRMKit·Info.plist·xcconfig를 준비하고, `xcode/Broadcast.xcodeproj`를 만든다.
   - 그다음 앱(Swift, C 브리지 `app/Core`, VRMKit)을 컴파일하고 보관(Archive)한 뒤, Apple 클라우드 서명으로 TestFlight에 올린다.

testflight 브랜치는 예전처럼 GitHub Actions가 서명해 올린다. main만 Xcode Cloud로 올리므로, 같은 빌드가 두 번 올라가지 않는다.

## 처음 한 번: Mac에서 워크플로 만들기 (30분쯤)

Xcode Cloud의 첫 워크플로는 Xcode에서만 만들 수 있다. 그다음부터는 App Store Connect 웹에서도 고칠 수 있다.

준비할 것:
- Xcode가 있는 Mac
- Apple Developer 계정 (App Store Connect의 앱 `io.github.videin.broadcast`가 있는 팀)
- 이 저장소에 권한이 있는 GitHub 계정
- **main에 이 설정(`xcode/`, `ios/xcode/`)이 들어가 있을 것**
  - Xcode Cloud는 main을 빌드하므로, 먼저 main에 병합해 GitHub 실행이 통과하게 한다.
  - 워크플로 ID가 아직 없으면 `Xcode Cloud (main)` 작업은 알림만 남기고 넘어간다.

1. 프로젝트를 만든다.
   - 받으려는 커밋의 GitHub Actions 실행이 `iOS SDK release`까지 통과해 있어야 한다. 그 실행이 SDK 묶음을 올린다.
   ```sh
   git clone https://github.com/VideiN/iPadOS-broadcasting.git
   cd iPadOS-broadcasting
   git checkout main
   DEVELOPMENT_TEAM=<팀 ID 10자리> bash ios/xcode/bootstrap.sh
   open xcode/Broadcast.xcodeproj
   ```
   - 팀 ID는 developer.apple.com › Membership에 있다.
2. Xcode › Broadcast 타깃 › Signing & Capabilities를 확인한다.
   - Automatically manage signing이 켜져 있고, 팀과 번들 ID `io.github.videin.broadcast`가 맞는지 본다.
   - 이 프로젝트 파일은 저장소에 올리지 않는다. 팀은 다음 단계의 환경 변수로 Xcode Cloud에 넘긴다.
3. Integrate › Create Workflow를 연다 (Report navigator › Cloud).
   - Xcode가 App Store Connect의 앱과 GitHub 저장소 연결을 묻는다. GitHub에 Xcode Cloud 앱을 설치해 이 저장소를 허락한다.
   - 워크플로 이름: `Main TestFlight`
   - Start Conditions:
     - 기본 Branch Changes를 지운다.
     - **Manual Start**를 추가하고 브랜치에 `main`을 넣는다.
     - GitHub이 API로 시작한 빌드는 수동 빌드로 친다.
   - Environment:
     - Xcode는 최신 정식판으로 둔다.
     - 환경 변수 `DEVELOPMENT_TEAM`: 팀 ID (비밀값 아님)
     - 환경 변수 `YOUTUBE_CLIENT_ID`: 유튜브 로그인 클라이언트 ID. **Secret으로 표시한다**. 없으면 앱 설정에서 사용자가 넣는다.
   - Actions: Archive, 플랫폼 iOS, 스킴 `Broadcast`. Deployment Preparation은 TestFlight (Internal Testing)
   - Post-Actions: TestFlight Internal Testing, 내부 테스트 그룹을 고른다.
4. Start Build로 `main`을 한 번 빌드한다.
   - 로그 `ci_post_clone.sh`에 `ios sdk key: …`와 `ready: …/Broadcast.xcodeproj`가 보이고, Archive와 TestFlight가 끝나는지 본다.
5. 워크플로 ID를 GitHub에 넣는다.
   - GitHub › Actions › **Xcode Cloud** 워크플로를 `workflows`로 실행하면 요약에 제품과 워크플로 ID가 찍힌다. ASC 키는 testflight 환경 비밀값을 쓴다.
   - 키가 있는 컴퓨터라면 `python3 ios/scripts/asc.py xcode-cloud-workflows`로도 된다.
   - 찍힌 `workflow <ID>: Main TestFlight`의 ID를 넣는다: GitHub › Settings › Environments › testflight › Variables › `XCODE_CLOUD_WORKFLOW_ID`
   - 같은 워크플로를 `start`로 실행하면 main을 바로 Xcode Cloud로 빌드한다 (CI를 기다리지 않고 다시 올릴 때).

그다음부터는 main에 푸시하고 CI가 통과하면 Xcode Cloud가 자동으로 TestFlight까지 간다.

## 알아 둘 것

- **Xcode Cloud 시간**
  - 개발자 프로그램에 월 25시간이 들어 있다.
  - libobs와 의존성은 GitHub이 빌드한다. Xcode Cloud는 앱만 컴파일하고 보관하므로 한 번에 10~15분쯤 걸린다.
- **버전**
  - `0.1.<GitHub 실행 번호>`이고, 빌드 번호(CFBundleVersion)는 Xcode Cloud가 매긴다.
  - 설정 › 정보의 빌드 줄은 `#<실행 번호> main`이다.
- **SDK 묶음이 없을 때**
  - `ci_post_clone.sh`가 1분씩 10번 기다린 뒤 실패한다. 그 커밋의 GitHub 실행이 `iOS SDK release`까지 갔는지 본다.
  - 묶음은 최근 10개만 남는다. 아주 오래된 커밋을 Xcode Cloud로 다시 빌드하려면, 그 커밋으로 GitHub 실행을 다시 돌린다.
- **API 키 권한**
  - 빌드를 시작하려면 키의 역할이 App Manager 이상이어야 한다.
  - `xcode-cloud-start`가 403을 내면 그 역할로 키를 다시 만들어 testflight 환경 비밀값을 바꾼다.
