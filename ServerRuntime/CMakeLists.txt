cmake_minimum_required(VERSION 3.25)

project(AmethystIOSServerRuntime VERSION 0.1.0 LANGUAGES C)

if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
    enable_language(CXX)
endif()

add_library(AmethystIOSServer STATIC
    Sources/amethyst_ios_server.c
)

if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
    target_sources(AmethystIOSServer PRIVATE
        Sources/apple_jli_main.cpp
    )
endif()

target_include_directories(AmethystIOSServer
    PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/Include>
        $<INSTALL_INTERFACE:include>
)

target_compile_features(AmethystIOSServer PUBLIC c_std_11)
target_compile_options(AmethystIOSServer PRIVATE -Wall -Wextra -Werror)
if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
    target_compile_features(AmethystIOSServer PRIVATE cxx_std_17)
endif()
set_target_properties(AmethystIOSServer PROPERTIES
    C_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN YES
    OUTPUT_NAME AmethystIOSServer
)

include(CTest)
if(BUILD_TESTING AND NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
    target_compile_definitions(AmethystIOSServer PRIVATE AIS_TESTING=1)
    add_executable(AmethystIOSServerTests
        Tests/amethyst_ios_server_tests.c
    )
    target_link_libraries(AmethystIOSServerTests PRIVATE AmethystIOSServer)
    target_compile_options(AmethystIOSServerTests PRIVATE -Wall -Wextra -Werror)
    add_test(NAME AmethystIOSServerTests COMMAND AmethystIOSServerTests)
endif()
