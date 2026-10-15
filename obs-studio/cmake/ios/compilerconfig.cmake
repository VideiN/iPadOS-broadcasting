# OBS CMake iOS compiler configuration module (iOS port)

include_guard(GLOBAL)

enable_language(OBJC)

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
