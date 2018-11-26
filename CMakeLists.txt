cmake_minimum_required(VERSION 3.8)
project(gumbo)

set(CMAKE_CXX_STANDARD 17)

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
        src/vector.c
        )

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
        src/vector.h
        )

add_library(gumbo STATIC
        # headers
        ${HEADERS}
        # sources
        ${SRC}
        )

file(GLOB HEAD_FILES
        src/gumbo.h
        src/tag_enum.h
        )
if(MSVC)
    list(APPEND HEAD_FILES visualc/include/strings.h)
endif()

file(INSTALL ${HEAD_FILES} DESTINATION ${CMAKE_BINARY_DIR}/include/gumbo)

target_include_directories(gumbo
        PUBLIC
        $<BUILD_INTERFACE:${CMAKE_BINARY_DIR}/include>
        $<INSTALL_INTERFACE:include>
        #For support include different way. (gumbo/gumbo.h or gumbo.h)
        $<BUILD_INTERFACE:${CMAKE_BINARY_DIR}/include/gumbo>
        $<INSTALL_INTERFACE:include/gumbo>
        )

install(FILES
        ${HEAD_FILES} DESTINATION
        ${CMAKE_INSTALL_PREFIX}/include/gumbo
        )

install(
        TARGETS gumbo
        EXPORT "${TARGETS_EXPORT_NAME}"
        LIBRARY DESTINATION "lib"
        ARCHIVE DESTINATION "lib"
        RUNTIME DESTINATION "bin"
        INCLUDES DESTINATION "${CMAKE_INSTALL_PREFIX}/include/gumbo"
        )

add_subdirectory(tests)