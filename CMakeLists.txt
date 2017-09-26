cmake_minimum_required(VERSION 3.1)

project(gumbo VERSION 0.10.1)

set(CMAKE_C_STANDARD_REQUIRED true)
set(CMAKE_C_STANDARD 99)

set(SRC
    src/attribute.c
    src/char_ref.c
    src/error.c
    src/parser.c
    src/string_buffer.c
    src/string_piece.c
    src/tag.c
    src/tokenizer.c
    src/utf8.c
    src/util.c
    src/vector.c)

set(HEADERS
    src/attribute.h
    src/char_ref.h
    src/error.h
    src/gumbo.h
    src/insertion_mode.h
    src/parser.h
    src/string_buffer.h
    src/string_piece.h
    src/tag_enum.h
    src/tag_gperf.h
    src/tag_sizes.h
    src/tag_strings.h
    src/tokenizer.h
    src/tokenizer_states.h
    src/token_type.h
    src/utf8.h
    src/util.h
    src/vector.h)

add_library(gumbo ${SRC})
target_include_directories(gumbo PUBLIC
    $<BUILD_INTERFACE:${PROJECT_SOURCE_DIR}/src>)

if(WIN32)
    list(APPEND HEADERS visualc/include/strings.h)
    target_include_directories(gumbo PUBLIC
        $<BUILD_INTERFACE:${PROJECT_SOURCE_DIR}/visualc/include>)
endif()

# Installation (https://github.com/forexample/package-example)

# Layout. This works for all platforms:
#   * <prefix>/lib/cmake/<PROJECT-NAME>
#   * <prefix>/lib/
#   * <prefix>/include/
set(config_install_dir "lib/cmake/${PROJECT_NAME}")
set(include_install_dir "include")

set(generated_dir "${CMAKE_CURRENT_BINARY_DIR}/generated")

# Configuration
set(version_config "${generated_dir}/${PROJECT_NAME}ConfigVersion.cmake")
set(project_config "${generated_dir}/${PROJECT_NAME}Config.cmake")
set(TARGETS_EXPORT_NAME "${PROJECT_NAME}Targets")
set(namespace "${PROJECT_NAME}::")

# Include module with fuction 'write_basic_package_version_file'
include(CMakePackageConfigHelpers)

# Configure '<PROJECT-NAME>ConfigVersion.cmake'
# Use:
#   * PROJECT_VERSION
write_basic_package_version_file(
    "${version_config}" COMPATIBILITY SameMajorVersion
)

# Configure '<PROJECT-NAME>Config.cmake'
# Use variables:
#   * TARGETS_EXPORT_NAME
#   * PROJECT_NAME
configure_package_config_file(
    "cmake/Config.cmake.in"
    "${project_config}"
    INSTALL_DESTINATION "${config_install_dir}"
)

# Targets:
#   * <prefix>/lib/libgumbo.a
#   * header location after install: <prefix>/include/gumbo.h
install(
    TARGETS gumbo
    EXPORT "${TARGETS_EXPORT_NAME}"
    LIBRARY DESTINATION "lib"
    ARCHIVE DESTINATION "lib"
    RUNTIME DESTINATION "bin"
    INCLUDES DESTINATION "${include_install_dir}"
)

# Headers:
#   * src/gumbo.h -> <prefix>/include/gumbo.h
install(
    FILES ${HEADERS}
    DESTINATION "${include_install_dir}"
)

# Config
#   * <prefix>/lib/cmake/gumbo/gumboConfig.cmake
#   * <prefix>/lib/cmake/gumbo/gumboConfigVersion.cmake
install(
    FILES "${project_config}" "${version_config}"
    DESTINATION "${config_install_dir}"
)

# Config
#   * <prefix>/lib/cmake/gumbo/gumboTargets.cmake
install(
    EXPORT "${TARGETS_EXPORT_NAME}"
    NAMESPACE "${namespace}"
    DESTINATION "${config_install_dir}"
)

include(CTest)
if(BUILD_TESTING)
    add_subdirectory(tests)
endif()
