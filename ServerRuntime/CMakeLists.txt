cmake_minimum_required(VERSION 3.25)

project(AmethystIOSServerRuntime VERSION 0.1.0 LANGUAGES C)

if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
    enable_language(CXX OBJC)
    add_compile_options(
        -Wno-nullability-completeness
        -Wno-objc-property-no-attribute
        -Wno-nonnull
    )
endif()

add_library(AmethystIOSServer STATIC
    Sources/amethyst_ios_server.c
)

if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
    target_sources(AmethystIOSServer PRIVATE
        Sources/apple_jli_main.cpp
        Sources/dyld_bypass_runtime_compat.m
        ../Natives/dyld_bypass_validation.m
        ../Natives/installer/ForgeDirectInstaller.m
        ../Natives/installer/NeoForgeDirectInstaller.m
        ../Natives/installer/ForgeProcessorExecutor.m
        ../Natives/external/fishhook/fishhook.c
    )
    set_source_files_properties(
        ../Natives/dyld_bypass_validation.m
        PROPERTIES
            COMPILE_DEFINITIONS AMETHYST_SERVER_RUNTIME=1
            COMPILE_OPTIONS -Wno-sign-compare
    )
    target_include_directories(AmethystIOSServer PRIVATE
        Sources
        ../Natives
        ../Natives/external/UnzipKit
        ../Natives/external/fishhook
    )
    target_link_libraries(AmethystIOSServer
        PUBLIC
        "-framework Foundation"
        "-F\${CMAKE_CURRENT_LIST_DIR}/../Natives/resources/Frameworks"
        "-framework UnzipKit"
    )
    target_compile_options(AmethystIOSServer PRIVATE
        $<$<COMPILE_LANGUAGE:OBJC>:-fobjc-arc>
        $<$<COMPILE_LANGUAGE:OBJC>:-Wno-nullability-completeness>
        $<$<COMPILE_LANGUAGE:OBJC>:-Wno-objc-property-no-attribute>
    )
    target_compile_definitions(AmethystIOSServer PRIVATE AMETHYST_SERVER_RUNTIME=1)
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
