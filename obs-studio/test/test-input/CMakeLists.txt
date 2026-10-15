cmake_minimum_required(VERSION 3.28...3.30)

option(ENABLE_TEST_INPUT "Build test sources" OFF)

if(NOT ENABLE_TEST_INPUT)
  target_disable(test-input)
  return()
endif()

if(OS_IOS)
  # iOS port: modules are linked statically
  add_library(test-input STATIC)
else()
  add_library(test-input MODULE)
endif()
add_library(OBS::test-input ALIAS test-input)

target_sources(
  test-input
  PRIVATE
    sync-async-source.c
    sync-audio-buffering.c
    sync-pair-aud.c
    sync-pair-vid.c
    test-filter.c
    test-input.c
    test-random.c
    test-sinewave.c
)

target_link_libraries(test-input PRIVATE OBS::libobs)

if(OS_IOS)
  obs_ios_static_module(test-input)
endif()

set_target_properties_obs(test-input PROPERTIES FOLDER "Tests and Examples" PREFIX "")
