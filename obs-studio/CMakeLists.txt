cmake_minimum_required(VERSION 3.28...3.30)

include("${CMAKE_CURRENT_SOURCE_DIR}/cmake/common/bootstrap.cmake" NO_POLICY_SCOPE)

project(obs-studio VERSION ${OBS_VERSION_CANONICAL})

if(CMAKE_HOST_SYSTEM_NAME MATCHES "Windows")
  include("${CMAKE_CURRENT_SOURCE_DIR}/cmake/windows/architecture.cmake")
  if(NOT OBS_PARENT_ARCHITECTURE STREQUAL CMAKE_VS_PLATFORM_NAME)
    return()
  endif()
endif()

include(compilerconfig)
include(defaults)
include(helpers)

# iOS port: build libobs and the modules that get linked statically into the
# app. Graphics backends, plugins and the frontend are added step by step.
if(OS_IOS)
  option(ENABLE_HEVC "Enable HEVC encoders" ON)
  option(ENABLE_UNIT_TESTS "Build unit tests (run on the iOS simulator)" OFF)

  add_subdirectory(libobs)
  add_subdirectory(libobs-metal)

  if(ENABLE_UNIT_TESTS)
    enable_testing()
    set(ENABLE_TEST_INPUT ON)
    add_subdirectory(test/test-input)
    add_subdirectory(test/cmocka)
    add_subdirectory(test/ios)
  endif()

  message_configuration()
  return()
endif()

option(ENABLE_FRONTEND "Enable building with UI (requires Qt)" ON)
option(ENABLE_SCRIPTING "Enable scripting support" ON)
option(ENABLE_HEVC "Enable HEVC encoders" ON)

add_subdirectory(libobs)
if(OS_WINDOWS)
  add_subdirectory(libobs-d3d11)
  add_subdirectory(libobs-winrt)
endif()
add_subdirectory(libobs-opengl)
if(OS_MACOS)
  add_subdirectory(libobs-metal)
endif()
add_subdirectory(plugins)

add_subdirectory(test/test-input)

add_subdirectory(frontend)

message_configuration()
