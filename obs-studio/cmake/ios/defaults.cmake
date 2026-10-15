# OBS CMake iOS defaults module (iOS port)

include_guard(GLOBAL)

# Enable find_package targets to become globally available targets
set(CMAKE_FIND_PACKAGE_TARGETS_GLOBAL TRUE)
# Ignore any dependent packages installed via Homebrew (they are built for macOS)
list(APPEND CMAKE_IGNORE_PREFIX_PATH "/opt/homebrew" "/usr/local")
# CMake re-roots find_* searches into the iOS SDK on Apple embedded platforms
# (CMAKE_FIND_ROOT_PATH_MODE_* = ONLY). Add the dependency prefixes as roots
# as well, so that they are searched as they are.
list(APPEND CMAKE_FIND_ROOT_PATH ${CMAKE_PREFIX_PATH})

# CMake turns every executable into an app bundle on iOS. Test executables are
# run directly on the simulator, so app targets have to enable MACOSX_BUNDLE themselves.
set(CMAKE_MACOSX_BUNDLE OFF)

# zlib comes from the iOS SDK (OBS_IOS_SDK_PATH is set in compilerconfig.cmake)
if(NOT DEFINED ZLIB_ROOT)
  set(ZLIB_ROOT "${OBS_IOS_SDK_PATH}/usr")
endif()

set(OBS_EXECUTABLE_DESTINATION "bin")
set(OBS_LIBRARY_DESTINATION "lib")
set(OBS_INCLUDE_DESTINATION "include/obs")
set(OBS_CMAKE_DESTINATION "lib/cmake")
