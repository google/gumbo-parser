#include "gumbo.h"
#include "parser.h"
#include "error.h"

#include <string>

#include "gtest/gtest.h"
#include "test_utils.h"

namespace {

class GumboErrorTest : public ::testing::Test {
 protected:
  GumboErrorTest() {}

  virtual ~GumboErrorTest() {

  }
};

TEST_F(GumboErrorTest, NewlineAfterLessThanSymbol) {
  const GumboOptions *options = &kGumboDefaultOptions;
  const char *input = "<\n";
  size_t input_len = strlen(input);
  GumboOutput *output = gumbo_parse_with_options(options, input, input_len);
  GumboVector *errors = &output->errors;
  GumboParser parser = { ._options = options };
  GumboStringBuffer msg;

  gumbo_string_buffer_init(&parser, &msg);
  for (size_t i=0; i < errors->length; i++) {
    GumboError *err = (GumboError *)errors->data[i];
    gumbo_string_buffer_clear(&parser, &msg);
    gumbo_caret_diagnostic_to_string(&parser, err, input, &msg);
  }
  gumbo_string_buffer_destroy(&parser, &msg);

  gumbo_destroy_output(options, output);
}

}
