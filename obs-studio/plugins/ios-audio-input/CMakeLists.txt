cmake_minimum_required(VERSION 3.28...3.30)

# iOS port: audio input source based on AVAudioSession + AVAudioEngine (mac-capture uses the CoreAudio HAL, which does
# not exist on iOS). Linked statically into the app.
add_library(ios-audio-input STATIC)
add_library(OBS::ios-audio-input ALIAS ios-audio-input)

target_sources(ios-audio-input PRIVATE ios-audio-input.m)
target_compile_options(ios-audio-input PRIVATE -fobjc-arc -fmodules)
target_link_libraries(
  ios-audio-input
  PRIVATE OBS::libobs "$<LINK_LIBRARY:FRAMEWORK,AVFAudio.framework>" "$<LINK_LIBRARY:FRAMEWORK,Foundation.framework>"
)

obs_ios_static_module(ios-audio-input)
