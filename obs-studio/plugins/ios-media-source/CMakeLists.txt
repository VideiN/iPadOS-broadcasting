cmake_minimum_required(VERSION 3.28...3.30)

# iOS port: media (video/audio file) source based on AVFoundation (plan D8: no FFmpeg video/audio decoders).
# Linked statically into the app.
add_library(ios-media-source STATIC)
add_library(OBS::ios-media-source ALIAS ios-media-source)

target_sources(ios-media-source PRIVATE ios-media-source.m)
target_compile_options(ios-media-source PRIVATE -fobjc-arc -fmodules)
target_link_libraries(
  ios-media-source
  PRIVATE
    OBS::libobs
    "$<LINK_LIBRARY:FRAMEWORK,AVFoundation.framework>"
    "$<LINK_LIBRARY:FRAMEWORK,CoreMedia.framework>"
    "$<LINK_LIBRARY:FRAMEWORK,CoreVideo.framework>"
)

obs_ios_static_module(ios-media-source)
