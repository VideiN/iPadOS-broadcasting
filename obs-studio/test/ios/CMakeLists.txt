# iOS port: tests run on the iOS simulator through CMAKE_CROSSCOMPILING_EMULATOR

# libobs without graphics
add_executable(test_libobs_ios test-libobs-ios.c)
target_link_libraries(test_libobs_ios PRIVATE OBS::libobs OBS::test-input)

add_test(NAME test_libobs_ios COMMAND test_libobs_ios)

# Rendering with the statically linked Metal renderer
add_executable(test_libobs_metal test-libobs-metal.c)
target_link_libraries(test_libobs_metal PRIVATE OBS::libobs OBS::libobs-metal)
target_compile_definitions(test_libobs_metal PRIVATE LIBOBS_DATA_DIR="${CMAKE_SOURCE_DIR}/libobs/data/")
# libobs-metal is Swift, so link with swiftc to pull in the Swift runtime
set_target_properties(test_libobs_metal PROPERTIES LINKER_LANGUAGE Swift)

add_test(NAME test_libobs_metal COMMAND test_libobs_metal)
set_tests_properties(test_libobs_metal PROPERTIES SKIP_RETURN_CODE 77)
