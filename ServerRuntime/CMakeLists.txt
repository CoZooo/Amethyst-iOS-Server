cmake_minimum_required(VERSION 3.25)

project(AmethystIOSServerRuntime VERSION 0.1.0 LANGUAGES C)

add_library(AmethystIOSServer STATIC
    Sources/amethyst_ios_server.c
)

target_include_directories(AmethystIOSServer
    PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/Include>
        $<INSTALL_INTERFACE:include>
)

target_compile_features(AmethystIOSServer PUBLIC c_std_11)
target_compile_options(AmethystIOSServer PRIVATE -Wall -Wextra -Werror)
set_target_properties(AmethystIOSServer PROPERTIES
    C_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN YES
    OUTPUT_NAME AmethystIOSServer
)

include(CTest)
if(BUILD_TESTING AND NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
    add_executable(AmethystIOSServerTests
        Tests/amethyst_ios_server_tests.c
    )
    target_link_libraries(AmethystIOSServerTests PRIVATE AmethystIOSServer)
    target_compile_options(AmethystIOSServerTests PRIVATE -Wall -Wextra -Werror)
    add_test(NAME AmethystIOSServerTests COMMAND AmethystIOSServerTests)
endif()

