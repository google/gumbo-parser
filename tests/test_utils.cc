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

#include "test_utils.h"

#include "error.h"
#include "util.h"

int GetChildCount(GumboNode* node) {
  if (node->type == GUMBO_NODE_DOCUMENT) {
    return node->v.document.children.length;
  } else {
    return node->v.element.children.length;
  }
}

GumboTag GetTag(GumboNode* node) {
  return node->v.element.tag;
}

GumboNode* GetChild(GumboNode* parent, int index) {
  if (parent->type == GUMBO_NODE_DOCUMENT) {
    return static_cast<GumboNode*>(parent->v.document.children.data[index]);
  } else {
    return static_cast<GumboNode*>(parent->v.element.children.data[index]);
  }
}

int GetAttributeCount(GumboNode* node) {
  return node->v.element.attributes.length;
}

GumboAttribute* GetAttribute(GumboNode* node, int index) {
  return static_cast<GumboAttribute*>(node->v.element.attributes.data[index]);
}

// Convenience function to do some basic assertions on the structure of the
// document (nodes are elements, nodes have the right tags) and then return
// the body node.
void GetAndAssertBody(GumboNode* root, GumboNode** body) {
  GumboNode* html = NULL;
  for (int i = 0; i < GetChildCount(root); ++i) {
    GumboNode* child = GetChild(root, i);
    if (child->type != GUMBO_NODE_ELEMENT) {
      ASSERT_EQ(GUMBO_NODE_COMMENT, child->type);
      continue;
    }
    ASSERT_TRUE(html == NULL);
    html = child;
  }
  ASSERT_TRUE(html != NULL);
  ASSERT_EQ(GUMBO_NODE_ELEMENT, html->type);
  EXPECT_EQ(GUMBO_TAG_HTML, GetTag(html));

  // There may be comment/whitespace nodes; this walks through the children of
  // <html> and assigns head/body based on them, or assert-fails if there are
  // fewer/more than 2 such nodes.
  GumboNode* head = NULL;
  *body = NULL;
  for (int i = 0; i < GetChildCount(html); ++i) {
    GumboNode* child = GetChild(html, i);
    if (child->type != GUMBO_NODE_ELEMENT) {
      continue;
    }

    if (!head) {
      head = child;
      EXPECT_EQ(GUMBO_TAG_HEAD, GetTag(head));
    } else if (!(*body)) {
      *body = child;
      EXPECT_EQ(GUMBO_TAG_BODY, GetTag(*body));
    } else {
      ASSERT_TRUE("More than two elements found inside <html>" != NULL);
    }
  }
  EXPECT_TRUE(head != NULL);
  ASSERT_TRUE(*body != NULL);
}

void SanityCheckPointers(const char* input, size_t input_length,
                         const GumboNode* node, int depth) {
  ASSERT_GE(input_length, (size_t) 0);
  ASSERT_TRUE(node != NULL);
  // There are some truly pathological HTML documents out there - the
  // integration tests for this include one where the DOM "tree" is actually a
  // linked list 27,500 nodes deep - and so we need a limit on the recursion
  // depth here to avoid blowing the stack. Alternatively, we could externalize
  // the stack and use an iterative algorithm, but that gets us very little for
  // the additional programming complexity.
  if (node->type == GUMBO_NODE_DOCUMENT || depth > 400) {
    // Don't sanity-check the document as well...we start with the root.
    return;
  }
  if (node->type == GUMBO_NODE_ELEMENT) {
    const GumboElement* element = &node->v.element;
    // Sanity checks on original* pointers, making sure they fall within the
    // original input.
    if (element->original_tag.data && element->original_tag.length) {
      EXPECT_GE(element->original_tag.data, input);
      EXPECT_LT(element->original_tag.data, input + input_length);
      EXPECT_LE(element->original_tag.length, input_length);
    }
    if (element->original_end_tag.data && element->original_tag.length) {
      EXPECT_GE(element->original_end_tag.data, input);
      EXPECT_LT(element->original_end_tag.data, input + input_length);
      EXPECT_LE(element->original_end_tag.length, input_length);
    }
    EXPECT_GE(element->start_pos.offset, 0);
    EXPECT_LE(element->start_pos.offset, input_length);
    EXPECT_GE(element->end_pos.offset, 0);
    EXPECT_LE(element->end_pos.offset, input_length);

    const GumboVector* children = &element->children;
    for (int i = 0; i < children->length; ++i) {
      const GumboNode* child = static_cast<const GumboNode*>(children->data[i]);
      // Checks on parent/child links.
      ASSERT_TRUE(child != NULL);
      EXPECT_EQ(node, child->parent);
      EXPECT_EQ(i, child->index_within_parent);
      SanityCheckPointers(input, input_length, child, depth + 1);
    }
  } else {
    const GumboText* text = &node->v.text;
    EXPECT_GE(text->original_text.data, input);
    EXPECT_LT(text->original_text.data, input + input_length);
    EXPECT_LE(text->original_text.length, input_length);
    EXPECT_GE(text->start_pos.offset, 0);
    EXPECT_LT(text->start_pos.offset, input_length);
  }
}

/*
 * NOTE:vmg
 *
 * The test suite used to have a very basic memory-checking allocator;
 * since we've simplified the API for defining custom memory allocators,
 * it is not trivial to implement the memcheck allocator naively. The new
 * API maps `realloc` calls (instead of `malloc` and `free`), which means
 * that you need to keep track of memory resizes and you can't just add and
 * substract allocated memory. Hence, the implementation of a naive memory
 * leak detector becomes more complex; it is still definitely doable, but at
 * that point we might as well wire up tcmalloc with its memleak allocator,
 * or simply run the suite under Valgrind
 */

GumboTest::GumboTest() :
    options_(kGumboDefaultOptions),
    errors_are_expected_(false),
    text_("")  {
  options_.max_errors = 100;
  parser_._options = &options_;
  parser_._output = static_cast<GumboOutput*>(gumbo_malloc(sizeof(GumboOutput)));
  gumbo_init_errors(&parser_);
}

GumboTest::~GumboTest() {
  if (!errors_are_expected_) {
    // TODO(jdtang): A googlemock matcher may be a more appropriate solution for
    // this; we only want to pretty-print errors that are not an expected
    // output of the test.
    for (int i = 0; i < parser_._output->errors.length && i < 1; ++i) {
      gumbo_print_caret_diagnostic(
          static_cast<GumboError*>(
              parser_._output->errors.data[i]), text_);
    }
  }
  gumbo_destroy_errors(&parser_);
  gumbo_free(parser_._output);
}
