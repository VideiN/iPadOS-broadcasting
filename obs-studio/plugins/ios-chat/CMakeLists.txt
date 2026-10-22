cmake_minimum_required(VERSION 3.28...3.30)

# iOS port: chat source. Messages are drawn by WebKit with the user's CSS and stacked on the GPU.
# Linked statically into the app.
add_library(ios-chat STATIC)
add_library(OBS::ios-chat ALIAS ios-chat)

target_sources(ios-chat PRIVATE ios-chat.m chat.h chat-message.m chat-renderer.m chat-test.m)
target_compile_options(ios-chat PRIVATE -fobjc-arc -fmodules)
target_link_libraries(
  ios-chat
  PRIVATE
    OBS::libobs
    "$<LINK_LIBRARY:FRAMEWORK,UIKit.framework>"
    "$<LINK_LIBRARY:FRAMEWORK,WebKit.framework>"
    "$<LINK_LIBRARY:FRAMEWORK,CoreGraphics.framework>"
)

obs_ios_static_module(ios-chat)
