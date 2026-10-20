cmake_minimum_required(VERSION 3.28...3.30)

# iOS port: text source drawn with UIKit/CoreText (text-freetype2 needs font files that iOS apps cannot read).
# Linked statically into the app.
add_library(ios-text STATIC)
add_library(OBS::ios-text ALIAS ios-text)

target_sources(ios-text PRIVATE ios-text.m)
target_compile_options(ios-text PRIVATE -fobjc-arc -fmodules)
target_link_libraries(
  ios-text
  PRIVATE
    OBS::libobs
    "$<LINK_LIBRARY:FRAMEWORK,UIKit.framework>"
    "$<LINK_LIBRARY:FRAMEWORK,CoreText.framework>"
    "$<LINK_LIBRARY:FRAMEWORK,CoreGraphics.framework>"
)

obs_ios_static_module(ios-text)
