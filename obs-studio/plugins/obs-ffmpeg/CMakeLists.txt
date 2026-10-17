cmake_minimum_required(VERSION 3.28...3.30)

if(OS_IOS)
  # iOS port: only the native mpegts output for SRT, linked statically into the app. FFmpeg is built with the mpegts
  # muxer only (no codecs); librist is not built, RIST URLs fail with a message (obs-ffmpeg-rist-ios.h).
  find_package(FFmpeg 6.1 REQUIRED avformat avcodec avutil)
  find_package(Libsrt REQUIRED)
  set(CMAKE_FIND_PACKAGE_PREFER_CONFIG TRUE)
  find_package(MbedTLS REQUIRED)
  set(CMAKE_FIND_PACKAGE_PREFER_CONFIG FALSE)

  add_library(obs-ffmpeg STATIC)
  add_library(OBS::ffmpeg ALIAS obs-ffmpeg)

  target_sources(
    obs-ffmpeg
    PRIVATE
      obs-ffmpeg-compat.h
      obs-ffmpeg-formats.h
      obs-ffmpeg-ios.c
      obs-ffmpeg-mpegts.c
      obs-ffmpeg-output.h
      obs-ffmpeg-rist-ios.h
      obs-ffmpeg-srt.h
      obs-ffmpeg-url.h
  )
  target_compile_options(obs-ffmpeg PRIVATE -Wno-shorten-64-to-32)
  target_compile_definitions(obs-ffmpeg PRIVATE NEW_MPEGTS_OUTPUT OBS_IOS_NO_RIST $<$<BOOL:${ENABLE_HEVC}>:ENABLE_HEVC>)
  # libsrt is C++ and uses mbedtls for encryption
  target_link_libraries(
    obs-ffmpeg
    PRIVATE OBS::libobs FFmpeg::avformat FFmpeg::avcodec FFmpeg::avutil Libsrt::Libsrt MbedTLS::mbedtls c++
  )

  obs_ios_static_module(obs-ffmpeg)
  set_target_properties_obs(obs-ffmpeg PROPERTIES FOLDER plugins/obs-ffmpeg PREFIX "")
  return()
endif()

option(ENABLE_FFMPEG_LOGGING "Enables obs-ffmpeg logging" OFF)
option(ENABLE_NEW_MPEGTS_OUTPUT "Use native SRT/RIST mpegts output" ON)

if(OS_LINUX OR OS_WINDOWS)
  option(ENABLE_FFMPEG_NVENC "Enable legacy FFmpeg NVENC encoder" OFF)
endif()

include(cmake/dependencies.cmake)

add_library(obs-ffmpeg MODULE)
add_library(OBS::ffmpeg ALIAS obs-ffmpeg)

add_subdirectory(ffmpeg-mux)

target_sources(
  obs-ffmpeg
  PRIVATE
    $<$<BOOL:${ENABLE_FFMPEG_LOGGING}>:obs-ffmpeg-logging.c>
    $<$<BOOL:${ENABLE_FFMPEG_NVENC}>:obs-ffmpeg-nvenc.c>
    $<$<BOOL:${ENABLE_NEW_MPEGTS_OUTPUT}>:obs-ffmpeg-mpegts.c>
    $<$<BOOL:${ENABLE_NEW_MPEGTS_OUTPUT}>:obs-ffmpeg-rist.h>
    $<$<BOOL:${ENABLE_NEW_MPEGTS_OUTPUT}>:obs-ffmpeg-srt.h>
    $<$<BOOL:${ENABLE_NEW_MPEGTS_OUTPUT}>:obs-ffmpeg-url.h>
    $<$<PLATFORM_ID:Linux,FreeBSD,OpenBSD>:obs-ffmpeg-vaapi.c>
    $<$<PLATFORM_ID:Linux,FreeBSD,OpenBSD>:vaapi-utils.c>
    $<$<PLATFORM_ID:Linux,FreeBSD,OpenBSD>:vaapi-utils.h>
    obs-ffmpeg-audio-encoders.c
    obs-ffmpeg-av1.c
    obs-ffmpeg-compat.h
    obs-ffmpeg-formats.h
    obs-ffmpeg-openh264.c
    obs-ffmpeg-hls-mux.c
    obs-ffmpeg-mux.c
    obs-ffmpeg-mux.h
    obs-ffmpeg-output.c
    obs-ffmpeg-output.h
    obs-ffmpeg-source.c
    obs-ffmpeg-video-encoders.c
    obs-ffmpeg.c
)

target_compile_options(obs-ffmpeg PRIVATE $<$<COMPILE_LANG_AND_ID:C,AppleClang,Clang>:-Wno-shorten-64-to-32>)
target_compile_definitions(
  obs-ffmpeg
  PRIVATE
    $<$<BOOL:${ENABLE_FFMPEG_LOGGING}>:ENABLE_FFMPEG_LOGGING>
    $<$<BOOL:${ENABLE_FFMPEG_NVENC}>:ENABLE_FFMPEG_NVENC>
    $<$<BOOL:${ENABLE_NEW_MPEGTS_OUTPUT}>:NEW_MPEGTS_OUTPUT>
)

target_link_libraries(
  obs-ffmpeg
  PRIVATE
    OBS::libobs
    OBS::media-playback
    OBS::opts-parser
    FFmpeg::avcodec
    FFmpeg::avfilter
    FFmpeg::avformat
    FFmpeg::avdevice
    FFmpeg::avutil
    FFmpeg::swscale
    FFmpeg::swresample
    $<$<PLATFORM_ID:Windows>:OBS::w32-pthreads>
    $<$<PLATFORM_ID:Windows>:ws2_32>
    $<$<PLATFORM_ID:Linux,FreeBSD,OpenBSD>:Libva::va>
    $<$<PLATFORM_ID:Linux,FreeBSD,OpenBSD>:Libva::drm>
    $<$<PLATFORM_ID:Linux,FreeBSD,OpenBSD>:Libpci::pci>
    $<$<PLATFORM_ID:Linux,FreeBSD,OpenBSD>:Libdrm::Libdrm>
    $<$<BOOL:${ENABLE_NEW_MPEGTS_OUTPUT}>:Librist::Librist>
    $<$<BOOL:${ENABLE_NEW_MPEGTS_OUTPUT}>:Libsrt::Libsrt>
)

if(OS_WINDOWS)
  if(CMAKE_VS_PLATFORM_NAME STREQUAL x64)
    target_sources(obs-ffmpeg PRIVATE texture-amf-opts.hpp texture-amf.cpp)
    target_link_libraries(obs-ffmpeg PRIVATE AMF::AMF)
  endif()

  configure_file(cmake/windows/obs-module.rc.in obs-ffmpeg.rc)
  target_sources(obs-ffmpeg PRIVATE obs-ffmpeg.rc)
endif()

set_target_properties_obs(obs-ffmpeg PROPERTIES FOLDER plugins/obs-ffmpeg PREFIX "")
