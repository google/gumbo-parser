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

#include <assert.h>
#include <ctype.h>
#include <strings.h>    // For strcasecmp.
#include <string.h>    // For strcasecmp.

// NOTE(jdtang): Keep this in sync with the GumboTag enum in the header.
// TODO(jdtang): Investigate whether there're efficiency benefits to putting the
// most common tag names first, or to putting them in alphabetical order and
// using a binary search.
const char* kGumboTagNames[] = {
  "html",
  "head",
  "title",
  "base",
  "link",
  "meta",
  "style",
  "script",
  "noscript",
  "template",
  "body",
  "article",
  "section",
  "nav",
  "aside",
  "h1",
  "h2",
  "h3",
  "h4",
  "h5",
  "h6",
  "hgroup",
  "header",
  "footer",
  "address",
  "p",
  "hr",
  "pre",
  "blockquote",
  "ol",
  "ul",
  "li",
  "dl",
  "dt",
  "dd",
  "figure",
  "figcaption",
  "main",
  "div",
  "a",
  "em",
  "strong",
  "small",
  "s",
  "cite",
  "q",
  "dfn",
  "abbr",
  "data",
  "time",
  "code",
  "var",
  "samp",
  "kbd",
  "sub",
  "sup",
  "i",
  "b",
  "u",
  "mark",
  "ruby",
  "rt",
  "rp",
  "bdi",
  "bdo",
  "span",
  "br",
  "wbr",
  "ins",
  "del",
  "image",
  "img",
  "iframe",
  "embed",
  "object",
  "param",
  "video",
  "audio",
  "source",
  "track",
  "canvas",
  "map",
  "area",
  "math",
  "mi",
  "mo",
  "mn",
  "ms",
  "mtext",
  "mglyph",
  "malignmark",
  "annotation-xml",
  "svg",
  "foreignobject",
  "desc",
  "table",
  "caption",
  "colgroup",
  "col",
  "tbody",
  "thead",
  "tfoot",
  "tr",
  "td",
  "th",
  "form",
  "fieldset",
  "legend",
  "label",
  "input",
  "button",
  "select",
  "datalist",
  "optgroup",
  "option",
  "textarea",
  "keygen",
  "output",
  "progress",
  "meter",
  "details",
  "summary",
  "menu",
  "menuitem",
  "applet",
  "acronym",
  "bgsound",
  "dir",
  "frame",
  "frameset",
  "noframes",
  "isindex",
  "listing",
  "xmp",
  "nextid",
  "noembed",
  "plaintext",
  "rb",
  "strike",
  "basefont",
  "big",
  "blink",
  "center",
  "font",
  "marquee",
  "multicol",
  "nobr",
  "spacer",
  "tt",
  "",                   // TAG_UNKNOWN
  "rtc",
  "",                   // TAG_LAST
};

const char* gumbo_normalized_tagname(GumboTag tag) {
  assert(tag <= GUMBO_TAG_LAST);
  return kGumboTagNames[tag];
}

// TODO(jdtang): Add test for this.
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

#ifdef SLOW_TAG_LOOKUP
GumboTag gumbo_tag_enum(const char* tagname) {
  for (int i = 0; i < GUMBO_TAG_LAST; ++i) {
    // TODO(jdtang): strcasecmp is non-portable, so if we want to support
    // non-GCC compilers, we'll need some #ifdef magic.  This source already has
    // pretty significant issues with MSVC6 anyway.
    if (strcasecmp(tagname, kGumboTagNames[i]) == 0) {
      return i;
    }
  }
  return GUMBO_TAG_UNKNOWN;
}
#else

/*
 * Generated with `mph`
 * ./mph -d2 -m2 -c1.33 < tag.in | emitc -s -l
 */
static int hash_tag(const unsigned char *kp, int len)
{
  static short g[] = {
    87, -1, -1, 54, 37, -1, 0, 63, -1, 4,
    87, 132, 149, -1, 43, 103, 78, 89, 126, 74,
    9, -1, 32, 68, 46, 132, 14, -1, -1, 147,
    77, 120, 101, 138, 38, -1, 135, 24, 94, -1,
    36, 88, 101, 29, -1, 83, 122, -1, 126, 148,
    145, 46, 90, 94, 83, 140, -1, 4, -1, 103,
    25, 0, 0, 129, 138, 0, 138, 53, -1, 0,
    77, 43, 0, -1, 90, 22, 30, 109, 71, 1,
    -1, 94, 20, -1, 27, 56, 0, 21, 72, 122,
    -1, -1, 0, 142, 72, 5, 11, 7, 43, 111,
    89, 96, 81, 48, 65, 27, 5, 73, -1, 57,
    137, 52, 0, 60, -1, 3, -1, 100, 149, 41,
    98, 118, 81, 0, 50, 30, -1, -1, 83, 10,
    20, 25, 2, 0, 118, 9, 39, 94, 35, 42,
    23, 75, 89, 31, 0, 148, 86, 6, 115, -1,
    49, 107, 5, 90, 4, 12, -1, 21, 16, -1,
    29, 39, -1, 96, 111, 96, 43, 43, 120, -1,
    46, 84, -1, 0, 146, 126, 24, -1, 28, 110,
    82, 42, 12, 84, -1, -1, -1, 0, 33, 12,
    86, 93, -1, 147, 95, 58, 90, 145, -1, -1,
  };

  static unsigned char T0[] = {
    196, 103, 27, 185, 60, 0, 58, 36, 180, 118,
    101, 180, 61, 125, 144, 167, 140, 104, 131, 195,
    176, 62, 79, 175, 195, 103, 116, 194, 122, 73,
    44, 119, 128, 23, 56, 188, 23, 114, 24, 156,
    32, 78, 136, 46, 3, 32, 165, 95, 136, 97,
    90, 65, 111, 121, 40, 106, 25, 108, 53, 99,
    181, 49, 18, 110, 72, 74, 50, 48, 141, 27,
    4, 125, 105, 92, 171, 60, 124, 1, 72, 96,
    178, 59, 58, 61, 0, 185, 12, 176, 111, 121,
    49, 170, 70, 48, 43, 82, 178, 157, 34, 62,
    137, 148, 110, 160, 96, 11, 50, 22, 12, 74,
    71, 143, 133, 129, 4, 86, 67, 168, 62, 130,
    41, 63, 101, 63, 112, 96, 146, 90, 5, 132,
    153, 95, 32, 15, 7, 80, 26, 57, 103, 191,
    83, 126, 134, 169, 55, 90, 55, 74, 58, 69,
    5, 99, 132, 58,
  };

  static unsigned char T1[] = {
    87, 14, 91, 162, 194, 198, 131, 1, 89, 2,
    154, 17, 98, 25, 7, 121, 145, 178, 28, 70,
    94, 135, 77, 129, 134, 137, 69, 128, 88, 126,
    114, 175, 92, 5, 89, 87, 3, 20, 88, 44,
    174, 194, 14, 73, 171, 21, 194, 117, 151, 175,
    139, 45, 110, 17, 127, 196, 106, 148, 124, 194,
    26, 190, 169, 118, 195, 59, 157, 150, 31, 197,
    147, 6, 143, 161, 79, 67, 134, 68, 163, 61,
    104, 124, 56, 39, 115, 99, 140, 101, 63, 91,
    124, 4, 134, 110, 132, 61, 150, 96, 116, 167,
    80, 174, 115, 169, 14, 184, 24, 47, 4, 188,
    60, 109, 64, 68, 148, 179, 168, 41, 80, 183,
    84, 156, 187, 18, 18, 119, 79, 169, 168, 148,
    88, 0, 122, 3, 169, 88, 139, 146, 88, 144,
    86, 148, 5, 150, 17, 105, 81, 137, 98, 113,
    120, 182, 69, 107,
  };

	int i, n;
	unsigned int f0, f1;

	if (len < 1 || len > 14)
		return -1;

	for (i=-45, f0=f1=0, n=0; n < len; ++n) {
    int c = tolower(kp[n]);
    if (c < 45 || c > 121)
			return -1;
		f0 += T0[i + c];
		f1 += T1[i + c];
		i += 77;
		if (i >= 109)
			i = -45;
	}
	return (g[f0 % 200] + g[f1 % 200]) % 150;
}

static int
case_memcmp(const char *s1, const char *s2, int n)
{
	while (n--) {
		unsigned char c1 = tolower(*s1++);
		unsigned char c2 = tolower(*s2++);
		if (c1 != c2)
			return (int)c1 - (int)c2;
	}
	return 0;
}

GumboTag gumbo_tagn_enum(const char* tagname, int length) {
  int position = hash_tag((const unsigned char *)tagname, length);
  if (position >= 0 && !case_memcmp(tagname, kGumboTagNames[position], length))
    return (GumboTag)position;
  return GUMBO_TAG_UNKNOWN;
}

GumboTag gumbo_tag_enum(const char* tagname) {
  return gumbo_tagn_enum(tagname, strlen(tagname));
}
#endif
