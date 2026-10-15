# iOS port: based on os-macos.cmake, without AppKit/Carbon/IOKit/CoreAudio HAL

target_link_libraries(
  libobs
  PRIVATE "$<LINK_LIBRARY:FRAMEWORK,CoreFoundation.framework>" "$<LINK_LIBRARY:FRAMEWORK,Foundation.framework>"
)

target_sources(
  libobs
  PRIVATE
    audio-monitoring/null/null-audio-monitoring.c
    obs-ios.m
    util/apple/cfstring-utils.h
    util/pipe-posix.c
    util/platform-cocoa.m
    util/platform-nix.c
    util/threading-posix.c
    util/threading-posix.h
)

target_compile_options(libobs PUBLIC "$<$<NOT:$<COMPILE_LANGUAGE:Swift>>:-Wno-strict-prototypes;-Wno-shorten-64-to-32>")

set_property(SOURCE obs-ios.m util/platform-cocoa.m PROPERTY COMPILE_OPTIONS -fobjc-arc)

# The app links the installed archives directly, so install the static
# dependencies and the generated header that obs-config.h includes.
install(TARGETS caption ARCHIVE DESTINATION "${OBS_LIBRARY_DESTINATION}")
install(FILES "${CMAKE_BINARY_DIR}/config/obsconfig.h" DESTINATION "${OBS_INCLUDE_DESTINATION}")
