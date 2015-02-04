// Copyright 2015 Kevin B. Hendricks, Stratford, Ontario,  All Rights Reserved.
// loosely based on a greatly simplified version of BeautifulSoup4 decode() routine
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// Author: Kevin Hendricks
//

#include <fstream>
#include <iostream>
#include <stdlib.h>
#include <string>

#include "gumbo.h"
#include "error.h"
#include "parser.h"
#include "string_buffer.h"

int main(int argc, char** argv) {
  if (argc != 2) {
      std::cout << "well_formed <html filename>\n";
      exit(EXIT_FAILURE);
  }
  const char* filename = argv[1];

  std::ifstream in(filename, std::ios::in | std::ios::binary);
  if (!in) {
    std::cout << "File " << filename << " not found!\n";
    exit(EXIT_FAILURE);
  }

  std::string contents;
  in.seekg(0, std::ios::end);
  contents.resize(in.tellg());
  in.seekg(0, std::ios::beg);
  in.read(&contents[0], contents.size());
  in.close();
 
  fprintf(stdout, "%s", contents.c_str());

  GumboOptions myoptions = kGumboDefaultOptions;
  myoptions.use_xhtml_rules = true;
  // leave this as false to prevent pre-mature stopping when no error exists
  myoptions.stop_on_first_error = false;
  
  GumboOutput* output = gumbo_parse_with_options(&myoptions, contents.data(), contents.length());

  GumboParser parser;
  parser._options = &myoptions; 
  const GumboVector* errors  = &output->errors;
  for (int i=0; i< errors->length; ++i) {
    GumboError* er = static_cast<GumboError*>(errors->data[i]);
    unsigned int linenum = er->position.line;
    unsigned int colnum = er->position.column;
    unsigned int typenum = er->type;
    GumboStringBuffer text;
    gumbo_string_buffer_init(&parser, &text);
    gumbo_error_to_string(&parser, er, &text);
    std::string errmsg(text.data, text.length);
    fprintf(stdout, "line: %d col: %d type %d %s\n", linenum, colnum, typenum, errmsg.c_str());
    gumbo_string_buffer_destroy(&parser, &text);
    gumbo_print_caret_diagnostic(&parser, er, contents.c_str());
  }
  gumbo_destroy_output(&myoptions, output);
}
