cmake_minimum_required(VERSION 3.28...3.30)

set(
  libobs_metal_sources
  CVPixelFormat+Extensions.swift
  MTLCullMode+Extensions.swift
  MTLOrigin+Extensions.swift
  MTLPixelFormat+Extensions.swift
  MTLRegion+Extensions.swift
  MTLSize+Extensions.swift
  MTLTexture+Extensions.swift
  MTLTextureDescriptor+Extensions.swift
  MTLTextureType+Extensions.swift
  MTLViewport+Extensions.swift
  MetalBuffer.swift
  MetalDevice.swift
  MetalError.swift
  MetalRenderState.swift
  MetalShader+Extensions.swift
  MetalShader.swift
  MetalStageBuffer.swift
  MetalTexture.swift
  OBSShader.swift
  OBSSwapChain.swift
  Sequence+Hashable.swift
  libobs+Extensions.swift
  libobs+SignalHandlers.swift
  metal-indexbuffer.swift
  metal-samplerstate.swift
  metal-shader.swift
  metal-stagesurf.swift
  metal-subsystem.swift
  metal-swapchain.swift
  metal-texture2d.swift
  metal-texture3d.swift
  metal-unimplemented.swift
  metal-vertexbuffer.swift
  metal-zstencilbuffer.swift
)

if(OS_IOS)
  # iOS port: libobs-metal is linked statically into the app.
  #
  # Its exports named gs_* would collide with the libobs functions of the same name, so they are renamed to
  # metal_gs_* in a generated copy of the sources. A generated lookup table (libobs_metal_get_export) maps the names
  # libobs asks for to these functions; the app registers it with gs_register_static_module("libobs-metal", ...).
  list(APPEND libobs_metal_sources OBSDisplayLink.swift)

  set(generated_dir "${CMAKE_CURRENT_BINARY_DIR}/generated")
  set(generated_sources "")
  set(exports "")

  foreach(source IN LISTS libobs_metal_sources)
    set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/${source}")

    file(READ "${CMAKE_CURRENT_SOURCE_DIR}/${source}" content)
    string(REGEX MATCHALL "@_cdecl\\(\"[a-z0-9_]+\"\\)" cdecls "${content}")
    foreach(cdecl IN LISTS cdecls)
      string(REGEX REPLACE "@_cdecl\\(\"([a-z0-9_]+)\"\\)" "\\1" export_name "${cdecl}")
      list(APPEND exports ${export_name})
    endforeach()

    string(REPLACE "@_cdecl(\"gs_" "@_cdecl(\"metal_gs_" content "${content}")
    file(WRITE "${generated_dir}/${source}.tmp" "${content}")
    configure_file("${generated_dir}/${source}.tmp" "${generated_dir}/${source}" COPYONLY)
    list(APPEND generated_sources "${generated_dir}/${source}")
  endforeach()

  list(REMOVE_DUPLICATES exports)
  set(LIBOBS_METAL_DECLARATIONS "")
  set(LIBOBS_METAL_EXPORTS "")
  foreach(export_name IN LISTS exports)
    if(export_name MATCHES "^gs_")
      set(symbol "metal_${export_name}")
    else()
      set(symbol "${export_name}")
    endif()
    string(APPEND LIBOBS_METAL_DECLARATIONS "extern void ${symbol}(void);\n")
    string(APPEND LIBOBS_METAL_EXPORTS "\t{\"${export_name}\", ${symbol}},\n")
  endforeach()
  configure_file(static-exports.c.in "${generated_dir}/static-exports.c" @ONLY)

  add_library(libobs-metal-swift STATIC ${generated_sources})
  target_link_libraries(libobs-metal-swift PRIVATE OBS::libobs)
  target_compile_options(
    libobs-metal-swift
    PRIVATE "SHELL:-import-objc-header ${CMAKE_CURRENT_SOURCE_DIR}/libobs-metal-Bridging-Header.h"
  )
  set_target_properties(
    libobs-metal-swift
    PROPERTIES FOLDER core Swift_MODULE_NAME libobs_metal Swift_LANGUAGE_VERSION 5
  )

  add_library(libobs-metal STATIC "${generated_dir}/static-exports.c")
  add_library(OBS::libobs-metal ALIAS libobs-metal)
  target_link_libraries(
    libobs-metal
    PUBLIC
      libobs-metal-swift
      "$<LINK_LIBRARY:FRAMEWORK,Metal.framework>"
      "$<LINK_LIBRARY:FRAMEWORK,QuartzCore.framework>"
      "$<LINK_LIBRARY:FRAMEWORK,UIKit.framework>"
  )
  set_target_properties(libobs-metal PROPERTIES FOLDER core OUTPUT_NAME obs-metal)
  set_target_properties(libobs-metal-swift PROPERTIES OUTPUT_NAME obs-metal-swift)

  target_enable_feature(libobs "Metal renderer")

  install(TARGETS libobs-metal libobs-metal-swift ARCHIVE DESTINATION "${OBS_LIBRARY_DESTINATION}")
  return()
endif()

add_library(libobs-metal SHARED)
add_library(OBS::libobs-metal ALIAS libobs-metal)

target_sources(libobs-metal PRIVATE ${libobs_metal_sources} libobs-metal-Bridging-Header.h)

target_link_libraries(libobs-metal PRIVATE OBS::libobs)

target_enable_feature(libobs "Metal renderer")

set_property(SOURCE OBSMetalRenderer.swift APPEND PROPERTY COMPILE_FLAGS -emit-objc-header)

set_target_properties_obs(
    libobs-metal
    PROPERTIES FOLDER core
               VERSION 0
               PREFIX ""
)

set_target_xcode_properties(
    libobs-metal
    PROPERTIES SWIFT_VERSION 6.0
               CLANG_ENABLE_OBJC_ARC YES
               CLANG_WARN_SUSPICIOUS_IMPLICIT_CONVERSION YES
               GCC_WARN_SHADOW YES
               CLANG_ENABLE_MODULES YES
               CLANG_MODULES_AUTOLINK YES
               GCC_STRICT_ALIASING YES
               DEFINES_MODULE YES
               SWIFT_OBJC_BRIDGING_HEADER "${CMAKE_CURRENT_SOURCE_DIR}/libobs-metal-Bridging-Header.h"
)
