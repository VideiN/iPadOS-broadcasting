# OBS CMake iOS helper functions module (iOS port)

include_guard(GLOBAL)

include(helpers_common)

# set_target_properties_obs: Set target properties for use in obs-studio
#
# Everything is linked statically into one app on iOS, so there is nothing to
# bundle or sign here.
function(set_target_properties_obs target)
  set(options "")
  set(oneValueArgs "")
  set(multiValueArgs PROPERTIES)
  cmake_parse_arguments(PARSE_ARGV 0 _STPO "${options}" "${oneValueArgs}" "${multiValueArgs}")

  message(DEBUG "Setting additional properties for target ${target}...")

  while(_STPO_PROPERTIES)
    list(POP_FRONT _STPO_PROPERTIES key value)
    set_property(TARGET ${target} PROPERTY ${key} "${value}")
  endwhile()
endfunction()

# target_export: Install a static library and its public headers
#
# The common implementation also generates a CMake package, which needs every
# static dependency to be exported as well. The iOS app links the installed
# archives directly, so only the files are installed.
function(target_export target)
  install(TARGETS ${target} ARCHIVE DESTINATION "${OBS_LIBRARY_DESTINATION}")

  get_target_property(obs_public_headers ${target} OBS_PUBLIC_HEADERS)
  if(obs_public_headers)
    foreach(header IN LISTS obs_public_headers)
      cmake_path(GET header PARENT_PATH header_dir)
      install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/${header}" DESTINATION "${OBS_INCLUDE_DESTINATION}/${header_dir}")
    endforeach()
  endif()
endfunction()

# obs_ios_static_module: Turn a plugin library into a module that can be linked statically
#
# Every plugin defines the same obs_module_* symbols, which would collide when
# several plugins are linked into one binary. They get a per-module prefix here,
# and a generated source file provides the `struct obs_static_module` that the
# app passes to obs_open_static_module(). For the module "test-input" it is
# named `obs_static_module_test_input`.
function(obs_ios_static_module target)
  string(MAKE_C_IDENTIFIER "${target}" prefix)

  set(
    module_symbols
    obs_module_load
    obs_module_unload
    obs_module_post_load
    obs_module_set_locale
    obs_module_free_locale
    obs_module_get_string
    obs_module_text
    obs_module_lookup
    obs_module_set_pointer
    obs_current_module
    obs_module_ver
    obs_module_name
    obs_module_description
    obs_module_author
  )
  foreach(symbol IN LISTS module_symbols)
    target_compile_definitions(${target} PRIVATE "${symbol}=${prefix}_${symbol}")
  endforeach()

  set(OBS_STATIC_MODULE_NAME "${target}")
  set(OBS_STATIC_MODULE_PREFIX "${prefix}")
  configure_file(
    "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/static-module.c.in"
    "${CMAKE_CURRENT_BINARY_DIR}/${target}-static-module.c"
    @ONLY
  )
  target_sources(${target} PRIVATE "${CMAKE_CURRENT_BINARY_DIR}/${target}-static-module.c")
endfunction()
