// Copyright 2013 Google Inc. All Rights Reserved.
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
// Author: jdtang@google.com (Jonathan Tang)
//
// Finds the URLs of all links in the page.

#include <stdlib.h>

#include <fstream>
#include <iostream>
#include <string>

#include "gumbo.h"

static void search_for_links(GumboNode* node) {
  if (node->type != GUMBO_NODE_ELEMENT) {
    return;
  }
  GumboAttribute* link = NULL;
  // handle main cases: href and src
  if ( ( node->v.element.tag == GUMBO_TAG_A     ) ||
       ( node->v.element.tag == GUMBO_TAG_AREA  ) ||
       ( node->v.element.tag == GUMBO_TAG_BASE  ) ||
       ( node->v.element.tag == GUMBO_TAG_IMAGE ) ||
       ( node->v.element.tag == GUMBO_TAG_LINK  ) ) {
      link = gumbo_get_attribute(&node->v.element.attributes, "href");

  }  else if ( ( node->v.element.tag == GUMBO_TAG_EMBED  ) ||
       ( node->v.element.tag == GUMBO_TAG_FORM   ) ||
       ( node->v.element.tag == GUMBO_TAG_FRAME  ) ||
       ( node->v.element.tag == GUMBO_TAG_IFRAME ) ||
       ( node->v.element.tag == GUMBO_TAG_IMG    ) ||
       ( node->v.element.tag == GUMBO_TAG_INPUT  ) ||
       ( node->v.element.tag == GUMBO_TAG_OBJECT ) ||
       ( node->v.element.tag == GUMBO_TAG_SCRIPT ) ||
       ( node->v.element.tag == GUMBO_TAG_SOURCE ) ) {
      link = gumbo_get_attribute(&node->v.element.attributes, "src");
  }
  if (link) {
      std::cout << link->value << std::endl;
      link = NULL;
  }

  // now handle special cases which can overlap with the above
  if (node->v.element.tag == GUMBO_TAG_IMAGE) {
      link = gumbo_get_attribute(&node->v.element.attributes, "xlink:href");
  } else if (node->v.element.tag == GUMBO_TAG_FORM) {
      link = gumbo_get_attribute(&node->v.element.attributes, "action");

  } else if (node->v.element.tag == GUMBO_TAG_OBJECT) {
      link = gumbo_get_attribute(&node->v.element.attributes, "data");
  }
  if (link) {
      std::cout << link->value << std::endl;
      link = NULL;
  }

  GumboVector* children = &node->v.element.children;
  for (unsigned int i = 0; i < children->length; ++i) {
    search_for_links(static_cast<GumboNode*>(children->data[i]));
  }
}

int main(int argc, char** argv) {
  if (argc != 2) {
    std::cout << "Usage: find_links <html filename>.\n";
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

  GumboOptions myoptions = kGumboDefaultOptions;
  myoptions.use_xhtml_rules = true;
  
  GumboOutput* output = gumbo_parse_with_options(&myoptions, contents.data(), contents.length());
  search_for_links(output->root);
  gumbo_destroy_output(&kGumboDefaultOptions, output);
}
