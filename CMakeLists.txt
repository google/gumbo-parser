cmake_minimum_required(VERSION 3.11)
project(gumbo)

set(CMAKE_CXX_STANDARD 17)

file(GLOB HEADERS_FILES 
		src/*.h
		)

file(GLOB EXPORT_HEADERS_FILES
        src/gumbo.h
        src/tag_enum.h
        )
		
if(MSVC)
    list(APPEND EXPORT_HEADERS_FILES visualc/include/strings.h)
endif()

file(INSTALL ${EXPORT_HEADERS_FILES} DESTINATION ${CMAKE_BINARY_DIR}/include/gumbo)		

file(GLOB SOURCES_FILES 
		src/*.c
		)

add_library(gumbo STATIC
        ${HEADERS_FILES}
        ${SOURCES_FILES}
        )

target_include_directories(gumbo
        PUBLIC
        $<BUILD_INTERFACE:${CMAKE_BINARY_DIR}/include>
        $<INSTALL_INTERFACE:include>
        # For support include different way. (gq/gumbo.h or gumbo.h)
        $<BUILD_INTERFACE:${CMAKE_BINARY_DIR}/include/gumbo>
        $<INSTALL_INTERFACE:include/gumbo>
        )

install(FILES
        ${EXPORT_HEADERS_FILES} DESTINATION
        ${CMAKE_INSTALL_PREFIX}/include/gumbo
        )

install(
        TARGETS gumbo
        EXPORT "${TARGETS_EXPORT_NAME}"
        LIBRARY DESTINATION "lib"
        ARCHIVE DESTINATION "lib"
        RUNTIME DESTINATION "bin"
        INCLUDES DESTINATION "include/gumbo"
        )

option(BUILD_GUMBO_TESTS "Builds gumbo tests" OFF)
if(BUILD_GUMBO_TESTS)
        add_subdirectory(tests)
endif()
