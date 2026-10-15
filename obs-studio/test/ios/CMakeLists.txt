# iOS port: libobs smoke test, run on the iOS simulator through CMAKE_CROSSCOMPILING_EMULATOR

add_executable(test_libobs_ios test-libobs-ios.c)
target_link_libraries(test_libobs_ios PRIVATE OBS::libobs OBS::test-input)

add_test(NAME test_libobs_ios COMMAND test_libobs_ios)
