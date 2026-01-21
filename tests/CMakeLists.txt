set(GTEST_ROOT "${CMAKE_INSTALL_PREFIX}/")
find_package(GTest REQUIRED)

add_executable(gumbo_tests
        test_utils.h
        attribute.cc
        char_ref.cc
        parser.cc
        string_buffer.cc
        string_piece.cc
        test_utils.cc
        tokenizer.cc
        utf8.cc
        vector.cc
        )

target_include_directories(gumbo_tests
        PRIVATE
        "${PROJECT_SOURCE_DIR}/src"
        )

target_link_libraries(gumbo_tests
        PRIVATE
        GTest::GTest
        GTest::Main
        gumbo
        )
