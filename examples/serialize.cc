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
// Serialize back to html / xhtml.

#include <fstream>
#include <iostream>
#include <stdlib.h>
#include <string>

#include "gumbo.h"

static std::string nonbreaking_inline  = "|a|abbr|acronym|b|bdo|big|cite|code|dfn|em|i|img|kbd|small|span|strike|strong|sub|sup|tt|";
static std::string empty_tags          = "|br|hr|input|img|meta|spacer|link|frame|base|image|";
static std::string preserve_whitespace = "|pre|textarea|script|style|";
static std::string special_handling    = "|html|body|";
static std::string no_entity_sub       = "|script|style|";

static inline void rtrim(std::string &s) 
{
  s.erase(s.find_last_not_of(" \n\r\t")+1);
}

static void replace_all(std::string &s, const char * s1, const char * s2)
{
  std::string t1(s1);
  size_t len = t1.length();
  size_t pos = s.find(t1);
  while (pos != std::string::npos) {
    s.replace(pos, len, s2);
    pos = s.find(t1, pos + len);
  }
}

static std::string substitute_xml_entities_into_text(const std::string &text)
{
  std::string result = text;
  // replacing & must come first 
  replace_all(result, "&", "&amp;");
  replace_all(result, "<", "&lt;");
  replace_all(result, ">", "&gt;");
  return result;
}

static std::string substitute_xml_entities_into_attributes(char quote, const std::string &text)
{
  std::string result = substitute_xml_entities_into_text(text);
  if (quote == '"') {
    replace_all(result,"\"","&quot;");
  }    
  else if (quote == '\'') {
    replace_all(result,"'","&apos;");
  }
 return result;
}

// forward declaration
static std::string serialize(GumboNode*);

// serialize children of a node
// may be invoked recursively
static std::string serialize_contents(GumboNode* node) {
  std::string contents        = "";
  std::string tagname         = gumbo_normalized_tagname(node->v.element.tag);
  std::string key             = "|" + tagname + "|";
  bool no_entity_substitution = no_entity_sub.find(key) != std::string::npos;
  bool keep_whitespace        = preserve_whitespace.find(key) != std::string::npos;
  bool is_inline              = nonbreaking_inline.find(key) != std::string::npos;

  // build up result for each child, recursively if need be
  GumboVector* children = &node->v.element.children;
  for (unsigned int i = 0; i < children->length; ++i) {
    GumboNode* child = static_cast<GumboNode*> (children->data[i]);
    if (child->type == GUMBO_NODE_TEXT) {
      if (no_entity_substitution) {
        contents.append(std::string(child->v.text.text));
      } else {
        contents.append(substitute_xml_entities_into_text(std::string(child->v.text.text)));
      }
    } else if (child->type == GUMBO_NODE_ELEMENT) {
      contents.append(serialize(child));
    } else if (child->type == GUMBO_NODE_WHITESPACE) {
      if (keep_whitespace or is_inline) {
        contents.append(std::string(child->v.text.text));
      }
    } else if (child->type != GUMBO_NODE_COMMENT) {
      // Does this actually exist: (child->type == GUMBO_NODE_CDATA)
      fprintf(stderr, "unknown element of type: %d\n", child->type); 
    }
  }
  return contents;
}

// serialize a GumboNode back to html/xhtml
// may be invoked recursively
static std::string serialize(GumboNode* node) {
  std::string close = "";
  std::string closeTag = "";
  std::string atts = "";

  // special case the document node
  if (node->type == GUMBO_NODE_DOCUMENT) {
    std::string results = "";
    if (node->v.document.has_doctype) {
      results.append("<!DOCTYPE ");
      results.append(node->v.document.name);
      std::string pi(node->v.document.public_identifier);
      if ((node->v.document.public_identifier != NULL) && !pi.empty() ) {
          results.append(" PUBLIC \"");
          results.append(node->v.document.public_identifier);
          results.append("\" \"");
          results.append(node->v.document.system_identifier);
          results.append("\"");
      }
      results.append(">\n");
    }
    results.append(serialize_contents(node));
    return results;
  }

  std::string tagname            = gumbo_normalized_tagname(node->v.element.tag);
  std::string key                = "|" + tagname + "|";
  bool need_special_handling     =  special_handling.find(key) != std::string::npos;
  bool is_empty_tag              = empty_tags.find(key) != std::string::npos;
  bool no_entity_substitution    = no_entity_sub.find(key) != std::string::npos;
  bool is_inline                 = nonbreaking_inline.find(key) != std::string::npos;

  // build attr string  
  const GumboVector * attribs = &node->v.element.attributes;
  for (int i=0; i< attribs->length; ++i) {
    GumboAttribute* at = static_cast<GumboAttribute*>(attribs->data[i]);
    atts.append(" ");
    atts.append(at->name);
    // how do we want to handle attributes with empty values
    // <input type="checkbox" checked />  or 
    // <input type="checkbox" checked="" /> 
    if ( (!std::string(at->value).empty())   || 
         (at->original_value.data[0] == '"') || 
         (at->original_value.data[0] == '\'') ) {
      char quote = at->original_value.data[0];
      std::string qs = "";
      if (quote == '\'') qs = std::string("'");
      if (quote == '"') qs = std::string("\"");
      atts.append("=");
      atts.append(qs);
      if (no_entity_substitution) {
        atts.append(at->value);
      } else {
        atts.append(substitute_xml_entities_into_attributes(quote, std::string(at->value)));
      }
      atts.append(qs);
    }
  }

  // determine closing tag type
  if (is_empty_tag) {
      close = "/";
  } else {
      closeTag = "</" + tagname + ">";
  }

  // serialize any children
  std::string contents = serialize_contents(node);
  if (need_special_handling) {
    rtrim(contents);
    contents.append("\n");
  }

  // build results
  std::string results;
  results.append("<"+tagname+atts+close+">");
  if (need_special_handling) results.append("\n");
  results.append(contents);
  results.append(closeTag);
  if (! is_inline) results.append("\n");

  return results;
}


int main(int argc, char** argv) {
  if (argc != 2) {
      std::cout << "clean_html <html filename>\n";
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

  GumboOutput* output = gumbo_parse(contents.c_str());
  std::cout << serialize(output->document) << std::endl;
  gumbo_destroy_output(&kGumboDefaultOptions, output);
}
