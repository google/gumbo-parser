# Copyright 2016 Google Inc. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
cmake_minimum_required(VERSION 2.8.7)

project(gumbo)
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY ${PROJECT_SOURCE_DIR}/lib)
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY ${CMAKE_LIBRARY_OUTPUT_DIRECTORY})

# Create library directory if it does not exist.
file(MAKE_DIRECTORY ${CMAKE_LIBRARY_OUTPUT_DIRECTORY})

# Compile as C99 (default is C89, which Gumbo is not written in).
if(CMAKE_COMPILER_IS_GNUCC OR
   CMAKE_COMPILER_IS_GNUCXX OR
   ${CMAKE_CXX_COMPILER_ID} STREQUAL Clang)
  set(CMAKE_C_FLAGS "-std=c99")
endif()

# Library target.
add_library(gumbo STATIC
        # headers
        include/gumbo/attribute.h
        include/gumbo/char_ref.h
        include/gumbo/error.h
        include/gumbo/gumbo.h
        include/gumbo/insertion_mode.h
        include/gumbo/parser.h
        include/gumbo/string_buffer.h
        include/gumbo/string_piece.h
        include/gumbo/tag_enum.h
        include/gumbo/tag_gperf.h
        include/gumbo/vector.h
        include/gumbo/util.h
        include/gumbo/utf8.h
        include/gumbo/tokenizer_states.h
        include/gumbo/tokenizer.h
        include/gumbo/token_type.h
        include/gumbo/tag_strings.h
        include/gumbo/tag_sizes.h
        # sources
        src/attribute.c
        src/vector.c
        src/util.c
        src/utf8.c
        src/tokenizer.c
        src/tag.c
        src/string_piece.c
        src/string_buffer.c
        src/parser.c
        src/error.c
        src/char_ref.c
        src/char_ref.rl
        )

target_include_directories(gumbo
        PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
        $<INSTALL_INTERFACE:include>
        #visualc/include
        )
if(WIN32)
  target_include_directories(gumbo
          PUBLIC
          visualc/include
          )
endif()

install(TARGETS gumbo
        LIBRARY DESTINATION lib
        ARCHIVE DESTINATION lib
        )

file(GLOB HEAD_FILES
        include/gumbo/gumbo.h
        include/gumbo/tag_enum.h
        )

install(FILES
        ${HEAD_FILES} DESTINATION
        ${CMAKE_INSTALL_PREFIX}/include/gumbo
        )

