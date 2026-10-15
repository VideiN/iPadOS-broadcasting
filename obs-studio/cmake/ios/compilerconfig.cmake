# OBS CMake iOS compiler configuration module (iOS port)

include_guard(GLOBAL)

enable_language(OBJC)

# Full path of the iOS SDK, which CMAKE_OSX_SYSROOT may only name (iphoneos/iphonesimulator)
if(IS_ABSOLUTE "${CMAKE_OSX_SYSROOT}")
  set(OBS_IOS_SDK_PATH "${CMAKE_OSX_SYSROOT}")
else()
  execute_process(
    COMMAND xcrun --sdk "${CMAKE_OSX_SYSROOT}" --show-sdk-path
    OUTPUT_VARIABLE OBS_IOS_SDK_PATH
    OUTPUT_STRIP_TRAILING_WHITESPACE
    COMMAND_ERROR_IS_FATAL ANY
  )
endif()

# Swift (libobs-metal) needs the iOS target triple and SDK; swiftc defaults to macOS otherwise.
if(NOT CMAKE_Swift_COMPILER_TARGET)
  if(OBS_IOS_SDK_PATH MATCHES "[Ss]imulator")
    set(CMAKE_Swift_COMPILER_TARGET "arm64-apple-ios${CMAKE_OSX_DEPLOYMENT_TARGET}-simulator")
  else()
    set(CMAKE_Swift_COMPILER_TARGET "arm64-apple-ios${CMAKE_OSX_DEPLOYMENT_TARGET}")
  endif()
endif()
string(APPEND CMAKE_Swift_FLAGS " -sdk \"${OBS_IOS_SDK_PATH}\"")

enable_language(Swift)

# Keep going on warnings while porting; the macOS-only code paths produce many of them.
if(NOT DEFINED CMAKE_COMPILE_WARNING_AS_ERROR)
  set(CMAKE_COMPILE_WARNING_AS_ERROR OFF)
endif()

include(compiler_common)

add_compile_options(
  "$<$<COMPILE_LANGUAGE:C,OBJC>:${_obs_clang_c_options}>"
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:${_obs_clang_cxx_options}>"
  "$<$<COMPILE_LANGUAGE:C,CXX,OBJC,OBJCXX>:-fopenmp-simd>"
)

# Enable dSYM generator for release builds
string(APPEND CMAKE_C_FLAGS_RELEASE " -g")
string(APPEND CMAKE_CXX_FLAGS_RELEASE " -g")
string(APPEND CMAKE_OBJC_FLAGS_RELEASE " -g")

add_compile_definitions(
  $<$<CONFIG:DEBUG>:DEBUG>
  $<$<COMPILE_LANGUAGE:C,CXX,OBJC,OBJCXX>:$<$<CONFIG:DEBUG>:_DEBUG>>
  $<$<COMPILE_LANGUAGE:C,CXX,OBJC,OBJCXX>:SIMDE_ENABLE_OPENMP>
)
