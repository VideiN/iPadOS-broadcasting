# iPadOS 앱 (P1 최소 앱)
#
# obs-studio의 iOS 빌드에서 add_subdirectory로 들어온다 (obs-studio/CMakeLists.txt의 ENABLE_APP).
# 앱 이름은 아직 정하지 않았다. 이름에 "OBS"를 쓰지 않는다 (계획 10.2).

set(APP_DISPLAY_NAME "Broadcast")
set(APP_EXECUTABLE "Broadcast")
set(APP_BUNDLE_ID "io.github.videin.broadcast")
set(APP_VERSION "0.1.0")
set(APP_BUILD_NUMBER "${OBS_BUILD_NUMBER}")

if(OBS_IOS_SDK_PATH MATCHES "[Ss]imulator")
  set(APP_SUPPORTED_PLATFORM "iPhoneSimulator")
  set(APP_PLATFORM_NAME "iphonesimulator")
else()
  set(APP_SUPPORTED_PLATFORM "iPhoneOS")
  set(APP_PLATFORM_NAME "iphoneos")
endif()

# libobs 호출을 모은 C 브리지
add_library(
  app-core
  STATIC
  Core/obs-core.c
  Core/obs-core.h
  Core/outputs.c
  Core/scenes.c
  Core/scenes.h
  Core/capture-format.m
  Core/capture-format.h
  Core/crash-log.m
  Core/crash-log.h
)
target_include_directories(app-core PUBLIC Core)
target_link_libraries(
  app-core
  PUBLIC
    OBS::libobs
    OBS::libobs-metal
    OBS::image-source
    OBS::avcapture
    OBS::ios-audio-input
    OBS::ios-text
    OBS::ios-media-source
    OBS::mac-videotoolbox
    OBS::coreaudio-encoder
    OBS::outputs
    OBS::filters
    OBS::ffmpeg
)
set_source_files_properties(Core/capture-format.m Core/crash-log.m PROPERTIES COMPILE_OPTIONS "-fobjc-arc;-fmodules")

configure_file(Info.plist.in "${CMAKE_CURRENT_BINARY_DIR}/Info.plist" @ONLY)

add_executable(
  app
  MACOSX_BUNDLE
  Sources/App.swift
  Sources/ContentView.swift
  Sources/PreviewView.swift
  Sources/Outputs.swift
  Sources/JSON.swift
  Sources/SceneModel.swift
  Sources/PropertiesView.swift
  Sources/FiltersView.swift
  Sources/PhotoImport.swift
  Sources/MainView.swift
  Sources/Settings.swift
)
target_link_libraries(app PRIVATE app-core)
# 정적 라이브러리 안의 Objective-C 카테고리(mac-avcapture의 AVCaptureDeviceFormat+OBSListable)는
# 심볼 참조가 없어 링커가 빼 버린다. -ObjC로 Objective-C 오브젝트 파일을 모두 넣는다.
target_link_options(app PRIVATE "LINKER:-ObjC")
target_compile_options(
  app
  PRIVATE -parse-as-library "SHELL:-import-objc-header ${CMAKE_CURRENT_SOURCE_DIR}/Sources/Bridging-Header.h"
)
set_target_properties(
  app
  PROPERTIES
    OUTPUT_NAME "${APP_EXECUTABLE}"
    MACOSX_BUNDLE TRUE
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_BINARY_DIR}/Info.plist"
    Swift_LANGUAGE_VERSION 5
)

# 번들에 리소스를 넣고 ad-hoc(fake) 서명한다 (계획 8.3).
# 실기기에서는 LiveContainer가 자체 인증서로 다시 서명한다.
# 시뮬레이터는 제한 엔타이틀먼트가 든 ad-hoc 서명을 거부하므로(Code Signature Invalid) 엔타이틀먼트 없이 서명한다.
if(APP_PLATFORM_NAME STREQUAL "iphoneos")
  set(codesign_entitlements --entitlements "${CMAKE_CURRENT_SOURCE_DIR}/app.entitlements")
else()
  set(codesign_entitlements "")
endif()

set(bundle_dir "$<TARGET_BUNDLE_CONTENT_DIR:app>")
# 의존성 설치 경로 (CMAKE_PREFIX_PATH의 첫 항목, CI는 .deps/ios-<플랫폼>)
list(GET CMAKE_PREFIX_PATH 0 deps_prefix)
add_custom_command(
  TARGET app
  POST_BUILD
  COMMAND "${CMAKE_COMMAND}" -E copy_directory "${CMAKE_SOURCE_DIR}/libobs/data" "${bundle_dir}/libobs"
  COMMAND
    "${CMAKE_COMMAND}" -E copy_directory "${CMAKE_SOURCE_DIR}/plugins/image-source/data"
    "${bundle_dir}/obs-plugins/image-source"
  COMMAND
    "${CMAKE_COMMAND}" -E copy_directory "${CMAKE_SOURCE_DIR}/plugins/mac-avcapture/data"
    "${bundle_dir}/obs-plugins/mac-avcapture"
  COMMAND
    "${CMAKE_COMMAND}" -E copy_directory "${CMAKE_SOURCE_DIR}/plugins/ios-audio-input/data"
    "${bundle_dir}/obs-plugins/ios-audio-input"
  COMMAND
    "${CMAKE_COMMAND}" -E copy_directory "${CMAKE_SOURCE_DIR}/plugins/ios-text/data"
    "${bundle_dir}/obs-plugins/ios-text"
  COMMAND
    "${CMAKE_COMMAND}" -E copy_directory "${CMAKE_SOURCE_DIR}/plugins/ios-media-source/data"
    "${bundle_dir}/obs-plugins/ios-media-source"
  COMMAND
    "${CMAKE_COMMAND}" -E copy_directory "${CMAKE_SOURCE_DIR}/plugins/mac-videotoolbox/data"
    "${bundle_dir}/obs-plugins/mac-videotoolbox"
  COMMAND
    "${CMAKE_COMMAND}" -E copy_directory "${CMAKE_SOURCE_DIR}/plugins/coreaudio-encoder/data"
    "${bundle_dir}/obs-plugins/coreaudio-encoder"
  COMMAND
    "${CMAKE_COMMAND}" -E copy_directory "${CMAKE_SOURCE_DIR}/plugins/obs-outputs/data"
    "${bundle_dir}/obs-plugins/obs-outputs"
  COMMAND
    "${CMAKE_COMMAND}" -E copy_directory "${CMAKE_SOURCE_DIR}/plugins/obs-filters/data"
    "${bundle_dir}/obs-plugins/obs-filters"
  COMMAND
    "${CMAKE_COMMAND}" -E copy_directory "${CMAKE_SOURCE_DIR}/plugins/obs-ffmpeg/data"
    "${bundle_dir}/obs-plugins/obs-ffmpeg"
  COMMAND "${CMAKE_COMMAND}" -E copy "${CMAKE_CURRENT_SOURCE_DIR}/Resources/test-pattern.png" "${bundle_dir}/"
  # 라이선스 화면용 (계획 10.1): 이 앱·OBS Studio(GPLv2+), OBS가 함께 넣은 코드, 의존성(ios/deps/build-deps.sh가 모음)
  COMMAND "${CMAKE_COMMAND}" -E make_directory "${bundle_dir}/licenses"
  COMMAND "${CMAKE_COMMAND}" -E copy "${CMAKE_SOURCE_DIR}/../LICENSE" "${bundle_dir}/licenses/app.txt"
  COMMAND "${CMAKE_COMMAND}" -E copy "${CMAKE_SOURCE_DIR}/COPYING" "${bundle_dir}/licenses/obs-studio.txt"
  COMMAND
    "${CMAKE_COMMAND}" -E copy "${CMAKE_SOURCE_DIR}/deps/libcaption/LICENSE.txt" "${bundle_dir}/licenses/libcaption.txt"
  COMMAND
    "${CMAKE_COMMAND}" -E copy "${CMAKE_SOURCE_DIR}/plugins/obs-outputs/librtmp/COPYING"
    "${bundle_dir}/licenses/librtmp.txt"
  COMMAND
    "${CMAKE_COMMAND}" -E copy "${CMAKE_SOURCE_DIR}/plugins/obs-filters/rnnoise/COPYING"
    "${bundle_dir}/licenses/rnnoise.txt"
  COMMAND "${CMAKE_COMMAND}" -E copy_directory "${deps_prefix}/share/licenses" "${bundle_dir}/licenses"
  # swiftc는 디버그 정보(dSYM)를 실행 파일 옆, 즉 번들 안에 만든다. 번들 안에 있으면 LiveContainer가 설치할 때
  # 서명하려다 "Failed to Sign …/Broadcast.dSYM/…" 경고를 낸다. 서명 전에 번들 밖으로 옮긴다.
  COMMAND
    sh -c
    "if [ -d \"$1/${APP_EXECUTABLE}.dSYM\" ]; then rm -rf \"$2\"; mv \"$1/${APP_EXECUTABLE}.dSYM\" \"$2\"; fi" sh
    "$<TARGET_BUNDLE_DIR:app>" "${CMAKE_CURRENT_BINARY_DIR}/${APP_EXECUTABLE}.app.dSYM"
  COMMAND codesign --force --sign - --timestamp=none ${codesign_entitlements} "$<TARGET_BUNDLE_DIR:app>"
  VERBATIM
)
