set(GTEST_ROOT "${PROJECT_SOURCE_DIR}/third_party/gtest")
find_package(GTest REQUIRED)

add_executable(gumbo_parser_unittests
    attribute.cc
    char_ref.cc
    parser.cc
    string_buffer.cc
    string_piece.cc
    test_utils.cc
    tokenizer.cc
    utf8.cc
    vector.cc)

target_include_directories(gumbo_parser_unittests
    PUBLIC "${PROJECT_SOURCE_DIR}/src"
           ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(gumbo_parser_unittests gumbo GTest::GTest GTest::Main)
add_test(gumbo_parser_unittests gumbo_parser_unittests)
