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
add_library(app-core STATIC Core/obs-core.c Core/obs-core.h Core/capture-format.m Core/capture-format.h)
target_include_directories(app-core PUBLIC Core)
target_link_libraries(
  app-core
  PUBLIC OBS::libobs OBS::libobs-metal OBS::image-source OBS::avcapture OBS::ios-audio-input
)
set_source_files_properties(Core/capture-format.m PROPERTIES COMPILE_OPTIONS "-fobjc-arc;-fmodules")

configure_file(Info.plist.in "${CMAKE_CURRENT_BINARY_DIR}/Info.plist" @ONLY)

add_executable(
  app
  MACOSX_BUNDLE
  Sources/App.swift
  Sources/ContentView.swift
  Sources/PreviewView.swift
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
  COMMAND "${CMAKE_COMMAND}" -E copy "${CMAKE_CURRENT_SOURCE_DIR}/Resources/test-pattern.png" "${bundle_dir}/"
  COMMAND codesign --force --sign - --timestamp=none ${codesign_entitlements} "$<TARGET_BUNDLE_DIR:app>"
  VERBATIM
)
