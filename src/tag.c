// Copyright 2011 Google Inc. All Rights Reserved.
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

#include "gumbo.h"
#include "util.h"

#include <assert.h>
#include <ctype.h>
#include <strings.h>    // For strcasecmp.
#include <string.h>    // For strcasecmp.

const char* kGumboTagNames[] = {
# include "tag_strings.h"
  "",                   // TAG_UNKNOWN
  "",                   // TAG_LAST
};

const char* gumbo_normalized_tagname(GumboTag tag) {
  assert(tag <= GUMBO_TAG_LAST);
  return kGumboTagNames[tag];
}

void gumbo_tag_from_original_text(GumboStringPiece* text) {
  if (text->data == NULL) {
    return;
  }

  assert(text->length >= 2);
  assert(text->data[0] == '<');
  assert(text->data[text->length - 1] == '>');
  if (text->data[1] == '/') {
    // End tag.
    assert(text->length >= 3);
    text->data += 2;    // Move past </
    text->length -= 3;
  } else {
    // Start tag.
    text->data += 1;    // Move past <
    text->length -= 2;
    // strnchr is apparently not a standard C library function, so I loop
    // explicitly looking for whitespace or other illegal tag characters.
    for (const char* c = text->data; c != text->data + text->length; ++c) {
      if (isspace(*c) || *c == '/') {
        text->length = c - text->data;
        break;
      }
    }
  }
}

/*
 * Override the `tolower` implementation in the perfect hash
 * to use ours. We need a custom `tolower` that only does ASCII
 * characters and is locale-independent to remain truthy to the
 * standard
 */
#define tolower(c) gumbo_tolower(c)
#include "tag_perf.h"

static int
case_memcmp(const char *s1, const char *s2, int n)
{
	while (n--) {
		unsigned char c1 = gumbo_tolower(*s1++);
		unsigned char c2 = gumbo_tolower(*s2++);
		if (c1 != c2)
			return (int)c1 - (int)c2;
	}
	return 0;
}

GumboTag gumbo_tagn_enum(const char* tagname, int length) {
  int position = perfhash((const unsigned char *)tagname, length);
  if (position >= 0 && !case_memcmp(tagname, kGumboTagNames[position], length))
    return (GumboTag)position;
  return GUMBO_TAG_UNKNOWN;
}

GumboTag gumbo_tag_enum(const char* tagname) {
  return gumbo_tagn_enum(tagname, strlen(tagname));
}
