cmake_minimum_required(VERSION 3.28...3.30)

if(OS_IOS)
  # iOS port: modules are linked statically
  add_library(image-source STATIC)
else()
  add_library(image-source MODULE)
endif()
add_library(OBS::image-source ALIAS image-source)

target_sources(image-source PRIVATE color-source.c image-source.c obs-slideshow.c obs-slideshow-mk2.c)

target_link_libraries(image-source PRIVATE OBS::libobs $<$<PLATFORM_ID:Windows>:OBS::w32-pthreads>)

if(OS_IOS)
  obs_ios_static_module(image-source)
endif()

if(OS_WINDOWS)
  configure_file(cmake/windows/obs-module.rc.in image-source.rc)
  target_sources(image-source PRIVATE image-source.rc)
endif()

set_target_properties_obs(image-source PROPERTIES FOLDER plugins PREFIX "")
