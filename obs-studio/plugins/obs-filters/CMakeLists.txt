cmake_minimum_required(VERSION 3.28...3.30)

if(OS_IOS)
  # iOS port: linked statically into the app. SpeexDSP is not built for iOS; noise suppression uses the bundled
  # RNNoise.
  add_library(obs-filters STATIC)
  set(ENABLE_SPEEXDSP OFF)
else()
  add_library(obs-filters MODULE)
endif()
add_library(OBS::filters ALIAS obs-filters)

target_sources(
  obs-filters
  PRIVATE
    async-delay-filter.c
    chroma-key-filter.c
    color-correction-filter.c
    color-grade-filter.c
    color-key-filter.c
    compressor-filter.c
    crop-filter.c
    eq-filter.c
    expander-filter.c
    gain-filter.c
    gpu-delay.c
    hdr-tonemap-filter.c
    invert-audio-polarity.c
    limiter-filter.c
    luma-key-filter.c
    mask-filter.c
    noise-gate-filter.c
    obs-filters.c
    scale-filter.c
    scroll-filter.c
    sdr-on-hdr-filter.c
    sharpness-filter.c
)

target_link_libraries(obs-filters PRIVATE OBS::libobs $<$<PLATFORM_ID:Windows>:OBS::w32-pthreads>)

include(cmake/speexdsp.cmake)
include(cmake/rnnoise.cmake)

if(OS_IOS)
  obs_ios_static_module(obs-filters)
endif()

if(OS_WINDOWS)
  configure_file(cmake/windows/obs-module.rc.in obs-filters.rc)
  target_sources(obs-filters PRIVATE obs-filters.rc)
endif()

set_target_properties_obs(obs-filters PROPERTIES FOLDER plugins PREFIX "")
