#!/bin/sh
# Xcode Cloud가 저장소를 받은 바로 뒤에 부른다 (P12). Xcode 프로젝트는 저장소에 없고 여기서 만든다:
# GitHub Release의 iOS SDK 묶음을 받고 XcodeGen으로 xcode/Broadcast.xcodeproj를 만든다 (ios/xcode/bootstrap.sh).
# 서명할 팀은 워크플로 환경 변수 DEVELOPMENT_TEAM, 유튜브 클라이언트 ID는 비밀 환경 변수 YOUTUBE_CLIENT_ID로 받는다.

set -eu
echo "Xcode Cloud build $CI_BUILD_NUMBER: $CI_WORKFLOW, ${CI_BRANCH:-?} ${CI_COMMIT:-?}"
exec bash "$CI_PRIMARY_REPOSITORY_PATH/ios/xcode/bootstrap.sh"
