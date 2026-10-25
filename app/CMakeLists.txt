# iPadOS 앱 (P1 최소 앱)
#
# obs-studio의 iOS 빌드에서 add_subdirectory로 들어온다 (obs-studio/CMakeLists.txt의 ENABLE_APP).
# 앱 이름은 아직 정하지 않았다. 이름에 "OBS"를 쓰지 않는다 (계획 10.2).

set(APP_DISPLAY_NAME "Broadcast")
set(APP_EXECUTABLE "Broadcast")
set(APP_BUNDLE_ID "io.github.videin.broadcast")
set(APP_BUILD_NUMBER "${OBS_BUILD_NUMBER}")

# 빌드 정보: 설치한 앱이 어느 CI 실행에서 나왔는지 LiveContainer 목록·설정·오버레이·로그에서 알아보게 한다 (BuildInfo.swift).
# 실행 번호는 GitHub Actions 목록의 "#번호". LiveContainer 목록은 CFBundleShortVersionString을 보여 주므로 버전 끝자리에 넣는다.
if(DEFINED ENV{GITHUB_RUN_NUMBER})
  set(APP_BUILD_RUN "$ENV{GITHUB_RUN_NUMBER}")
  set(APP_BUILD_RUN_ID "$ENV{GITHUB_RUN_ID}")
  set(APP_BUILD_REPOSITORY "$ENV{GITHUB_REPOSITORY}")
  set(APP_BUILD_COMMIT "$ENV{GITHUB_SHA}")
  # PR이면 GITHUB_REF_NAME이 "<번호>/merge"라서 PR의 브랜치를 쓴다
  if(NOT "$ENV{GITHUB_HEAD_REF}" STREQUAL "")
    set(APP_BUILD_BRANCH "$ENV{GITHUB_HEAD_REF}")
  else()
    set(APP_BUILD_BRANCH "$ENV{GITHUB_REF_NAME}")
  endif()
else()
  set(APP_BUILD_RUN "0")
  set(APP_BUILD_RUN_ID "")
  set(APP_BUILD_REPOSITORY "")
  set(APP_BUILD_COMMIT "")
  set(APP_BUILD_BRANCH "")
endif()
string(TIMESTAMP APP_BUILD_TIME "%Y-%m-%dT%H:%M:%SZ" UTC)
# Info.plist에 그대로 들어가므로 XML 특수 문자를 바꾼다
foreach(_var IN ITEMS APP_BUILD_BRANCH APP_BUILD_REPOSITORY)
  string(REPLACE "&" "&amp;" ${_var} "${${_var}}")
  string(REPLACE "<" "&lt;" ${_var} "${${_var}}")
  string(REPLACE ">" "&gt;" ${_var} "${${_var}}")
endforeach()
set(APP_VERSION "0.1.${APP_BUILD_RUN}")

if(OBS_IOS_SDK_PATH MATCHES "[Ss]imulator")
  set(APP_SUPPORTED_PLATFORM "iPhoneSimulator")
  set(APP_PLATFORM_NAME "iphonesimulator")
else()
  set(APP_SUPPORTED_PLATFORM "iPhoneOS")
  set(APP_PLATFORM_NAME "iphoneos")
endif()

# Xcode가 Info.plist에 넣는 빌드 도구 정보 (DTXcode, DTSDKName …). App Store Connect는 올린 빌드가 요구하는 SDK·Xcode로
# 만들어졌는지 이 값으로 본다. 이 앱은 Xcode 프로젝트가 아니라 CMake로 빌드하므로 직접 넣는다 (TestFlight, 2026-10-24)
execute_process(
  COMMAND xcrun --sdk ${APP_PLATFORM_NAME} --show-sdk-version
  OUTPUT_VARIABLE APP_SDK_VERSION
  OUTPUT_STRIP_TRAILING_WHITESPACE
  ERROR_QUIET
)
execute_process(
  COMMAND xcrun --sdk ${APP_PLATFORM_NAME} --show-sdk-build-version
  OUTPUT_VARIABLE APP_SDK_BUILD
  OUTPUT_STRIP_TRAILING_WHITESPACE
  ERROR_QUIET
)
execute_process(COMMAND xcodebuild -version OUTPUT_VARIABLE _xcode_version ERROR_QUIET)
execute_process(COMMAND sw_vers -buildVersion OUTPUT_VARIABLE APP_BUILD_MACHINE_OS OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
# "Xcode 26.0.1\nBuild version 17A400" → DTXcode 2601, DTXcodeBuild 17A400
set(APP_XCODE "")
set(APP_XCODE_BUILD "")
if(_xcode_version MATCHES "Xcode ([0-9]+)\\.?([0-9]*)\\.?([0-9]*)")
  set(_minor "${CMAKE_MATCH_2}")
  set(_patch "${CMAKE_MATCH_3}")
  if(_minor STREQUAL "")
    set(_minor 0)
  endif()
  if(_patch STREQUAL "")
    set(_patch 0)
  endif()
  math(EXPR APP_XCODE "${CMAKE_MATCH_1} * 100 + ${_minor} * 10 + ${_patch}")
endif()
if(_xcode_version MATCHES "Build version ([0-9A-Za-z]+)")
  set(APP_XCODE_BUILD "${CMAKE_MATCH_1}")
endif()
message(STATUS "App toolchain: SDK ${APP_PLATFORM_NAME}${APP_SDK_VERSION} (${APP_SDK_BUILD}), Xcode ${APP_XCODE} (${APP_XCODE_BUILD})")

# 유튜브 로그인(P8)의 Google OAuth 클라이언트 ID (iOS 유형). Google API 약관상 오픈 소스 코드에는 넣지 않고,
# CI가 저장소 비밀값(YOUTUBE_CLIENT_ID)으로 넘긴다. Info.plist에는 16진수로 넣는다 (번들을 글자로 훑어서는 안 보이게).
# 비어 있으면 앱 설정에서 사용자가 자기 클라이언트 ID를 넣는다.
set(APP_YOUTUBE_CLIENT_ID "" CACHE STRING "Google OAuth iOS client ID for YouTube login")
string(STRIP "${APP_YOUTUBE_CLIENT_ID}" _youtube_client_id)
set(APP_YOUTUBE_CLIENT_HEX "")
if(_youtube_client_id)
  # 값은 찍지 않는다
  if(NOT _youtube_client_id MATCHES "^[0-9]+-[0-9A-Za-z_]+\\.apps\\.googleusercontent\\.com$")
    message(FATAL_ERROR "APP_YOUTUBE_CLIENT_ID is not an iOS OAuth client ID (...apps.googleusercontent.com)")
  endif()
  string(HEX "${_youtube_client_id}" APP_YOUTUBE_CLIENT_HEX)
  message(STATUS "YouTube client ID: built in")
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
    OBS::ios-chat
    OBS::mac-videotoolbox
    OBS::coreaudio-encoder
    OBS::outputs
    OBS::filters
    OBS::ffmpeg
)
target_sources(app-core PRIVATE Core/avatar-source.c)
target_link_libraries(app-core PUBLIC "$<LINK_LIBRARY:FRAMEWORK,IOSurface.framework>")
set_source_files_properties(Core/capture-format.m Core/crash-log.m PROPERTIES COMPILE_OPTIONS "-fobjc-arc;-fmodules")

# 아바타 소스 (P9): VRM 모델을 RealityKit으로 그리는 VRMKit (github.com/tattn/VRMKit, MIT). 고정한 커밋을 받아 SwiftPM의
# 세 타깃(VRMKit, VRMKitRuntime, VRMRealityKit)을 같은 이름의 Swift 모듈로 빌드한다. SwiftPM이 해 주던 것은 Vendor/에:
# 의존성 swift-simd-compat(Apple에서는 simd 그대로)와 VRMRealityKit의 Bundle.module(→ 앱 번들, MToon metallib 복사)
include(FetchContent)
set(VRMKIT_COMMIT 6302146e58862fd00402a17be1f2c0dbff6dd167)
FetchContent_Declare(
  vrmkit
  URL "https://github.com/tattn/VRMKit/archive/${VRMKIT_COMMIT}.tar.gz"
  URL_HASH SHA256=62265ae684e92b21352ca3dd8733a3755f5a1db5f85b7c0941e33f2007dfccc8
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE
)
FetchContent_MakeAvailable(vrmkit)

set(vrmkit_module_dir "${CMAKE_CURRENT_BINARY_DIR}/swift-modules")
file(GLOB_RECURSE vrmkit_sources "${vrmkit_SOURCE_DIR}/Sources/VRMKit/*.swift")
file(GLOB_RECURSE vrmkit_runtime_sources "${vrmkit_SOURCE_DIR}/Sources/VRMKitRuntime/*.swift")
file(GLOB_RECURSE vrmkit_realitykit_sources "${vrmkit_SOURCE_DIR}/Sources/VRMRealityKit/*.swift")
add_library(SIMDCompat STATIC Vendor/SIMDCompat.swift)
add_library(VRMKit STATIC ${vrmkit_sources})
add_library(VRMKitRuntime STATIC ${vrmkit_runtime_sources})
add_library(VRMRealityKit STATIC ${vrmkit_realitykit_sources} Vendor/VRMRealityKit+Bundle.swift)
target_link_libraries(VRMKit PUBLIC SIMDCompat)
target_link_libraries(VRMKitRuntime PUBLIC VRMKit)
target_link_libraries(VRMRealityKit PUBLIC VRMKitRuntime)
foreach(_target IN ITEMS SIMDCompat VRMKit VRMKitRuntime VRMRealityKit)
  set_target_properties(${_target} PROPERTIES Swift_LANGUAGE_VERSION 6 Swift_MODULE_DIRECTORY "${vrmkit_module_dir}")
  target_include_directories(${_target} PUBLIC "${vrmkit_module_dir}")
endforeach()
# 세 모듈은 package 접근 수준으로 서로를 부른다
foreach(_target IN ITEMS VRMKit VRMKitRuntime VRMRealityKit)
  target_compile_options(${_target} PRIVATE "SHELL:-package-name VRMKit")
endforeach()
if(APP_PLATFORM_NAME STREQUAL "iphoneos")
  set(vrmkit_metallib "${vrmkit_SOURCE_DIR}/Sources/VRMRealityKit/Resources/MToon-ios.metallib")
else()
  set(vrmkit_metallib "${vrmkit_SOURCE_DIR}/Sources/VRMRealityKit/Resources/MToon-iossim.metallib")
endif()

configure_file(Info.plist.in "${CMAKE_CURRENT_BINARY_DIR}/Info.plist" @ONLY)

add_executable(
  app
  MACOSX_BUNDLE
  Sources/App.swift
  Sources/BuildInfo.swift
  Sources/ContentView.swift
  Sources/PreviewView.swift
  Sources/Outputs.swift
  Sources/JSON.swift
  Sources/SceneModel.swift
  Sources/PropertiesView.swift
  Sources/FiltersView.swift
  Sources/MainView.swift
  Sources/Settings.swift
  Sources/YouTube.swift
  Sources/Chat.swift
  Sources/FaceLink.swift
  Sources/Avatar.swift
)
target_link_libraries(app PRIVATE app-core VRMRealityKit)
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
    "${CMAKE_COMMAND}" -E copy_directory "${CMAKE_SOURCE_DIR}/plugins/ios-chat/data"
    "${bundle_dir}/obs-plugins/ios-chat"
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
  COMMAND "${CMAKE_COMMAND}" -E copy "${vrmkit_metallib}" "${bundle_dir}/"
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
  COMMAND "${CMAKE_COMMAND}" -E copy "${vrmkit_SOURCE_DIR}/LICENSE" "${bundle_dir}/licenses/vrmkit.txt"
  # swiftc는 디버그 정보(dSYM)를 실행 파일 옆, 즉 번들 안에 만든다. 번들 안에 있으면 LiveContainer가 설치할 때
  # 서명하려다 "Failed to Sign …/Broadcast.dSYM/…" 경고를 낸다. 서명 전에 번들 밖으로 옮긴다.
  COMMAND
    sh -c
    "if [ -d \"$1/${APP_EXECUTABLE}.dSYM\" ]; then rm -rf \"$2\"; mv \"$1/${APP_EXECUTABLE}.dSYM\" \"$2\"; fi" sh
    "$<TARGET_BUNDLE_DIR:app>" "${CMAKE_CURRENT_BINARY_DIR}/${APP_EXECUTABLE}.app.dSYM"
  # 앱 아이콘 (TestFlight에 올리려면 필요): 에셋 카탈로그를 Assets.car와 아이콘 PNG로 만들고, actool이 내놓는
  # Info.plist 조각(CFBundleIcons~ipad)을 번들의 Info.plist에 합친다. 다시 빌드할 때를 위해 먼저 지운다
  COMMAND
    xcrun actool "${CMAKE_CURRENT_SOURCE_DIR}/Resources/Assets.xcassets" --compile "${bundle_dir}" --platform
    "${APP_PLATFORM_NAME}" --minimum-deployment-target "${CMAKE_OSX_DEPLOYMENT_TARGET}" --target-device ipad --app-icon
    AppIcon --output-partial-info-plist "${CMAKE_CURRENT_BINARY_DIR}/assetcatalog_generated_info.plist" --output-format
    human-readable-text --errors --warnings
  COMMAND
    sh -c
    "for key in CFBundleIcons CFBundleIcons~ipad; do /usr/libexec/PlistBuddy -c \"Delete :$key\" \"$1\" >/dev/null 2>&1; done; /usr/libexec/PlistBuddy -c \"Merge $2\" \"$1\""
    sh "${bundle_dir}/Info.plist" "${CMAKE_CURRENT_BINARY_DIR}/assetcatalog_generated_info.plist"
  COMMAND codesign --force --sign - --timestamp=none ${codesign_entitlements} "$<TARGET_BUNDLE_DIR:app>"
  VERBATIM
)
