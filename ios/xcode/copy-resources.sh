#!/bin/bash
# Xcode 빌드의 Run Script 단계 (P12, xcode/project.yml): CMake 빌드의 POST_BUILD(app/CMakeLists.txt)와 같은 파일을
# 앱 번들에 넣는다. 아이콘(에셋 카탈로그)과 서명은 Xcode가 한다.
# 빌드 설정(REPO_ROOT, SDK_DIR, VRMKIT_DIR, TARGET_BUILD_DIR, CONTENTS_FOLDER_PATH, PLATFORM_NAME)을 환경 변수로 받는다.

set -euo pipefail

bundle="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH"
obs="$REPO_ROOT/obs-studio"

copy_dir() {
  rm -rf "$2"
  mkdir -p "$(dirname "$2")"
  cp -R "$1" "$2"
}

copy_dir "$obs/libobs/data" "$bundle/libobs"
for plugin in image-source mac-avcapture ios-audio-input ios-text ios-media-source ios-chat mac-videotoolbox \
  coreaudio-encoder obs-outputs obs-filters obs-ffmpeg; do
  copy_dir "$obs/plugins/$plugin/data" "$bundle/obs-plugins/$plugin"
done
cp "$REPO_ROOT/app/Resources/test-pattern.png" "$bundle/"

if [ "$PLATFORM_NAME" = iphoneos ]; then
  cp "$VRMKIT_DIR/Sources/VRMRealityKit/Resources/MToon-ios.metallib" "$bundle/"
else
  cp "$VRMKIT_DIR/Sources/VRMRealityKit/Resources/MToon-iossim.metallib" "$bundle/"
fi

# 라이선스 화면용 (계획 10.1): 이 앱·OBS Studio, OBS가 함께 넣은 코드, 의존성(SDK 묶음의 share/licenses), VRMKit
licenses="$bundle/licenses"
rm -rf "$licenses"
mkdir -p "$licenses"
cp "$REPO_ROOT/LICENSE" "$licenses/app.txt"
cp "$obs/COPYING" "$licenses/obs-studio.txt"
cp "$obs/deps/libcaption/LICENSE.txt" "$licenses/libcaption.txt"
cp "$obs/plugins/obs-outputs/librtmp/COPYING" "$licenses/librtmp.txt"
cp "$obs/plugins/obs-filters/rnnoise/COPYING" "$licenses/rnnoise.txt"
cp -R "$SDK_DIR/share/licenses/." "$licenses/"
cp "$VRMKIT_DIR/LICENSE" "$licenses/vrmkit.txt"
echo "copied OBS data, plugin data, metallib and $(ls "$licenses" | wc -l | tr -d ' ') license files into $bundle"
