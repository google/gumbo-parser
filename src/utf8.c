// Copyright 2010 Google Inc. All Rights Reserved.
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

#include "utf8.h"

#include <assert.h>
#include <stdint.h>
#include <string.h>
#include <strings.h>    // For strncasecmp.

#include "error.h"
#include "gumbo.h"
#include "parser.h"
#include "util.h"
#include "vector.h"

const int kUtf8ReplacementChar = 0xFFFD;

// Reference material:
// Wikipedia: http://en.wikipedia.org/wiki/UTF-8#Description
// RFC 3629: http://tools.ietf.org/html/rfc3629
// HTML5 Unicode handling:
// http://www.whatwg.org/specs/web-apps/current-work/multipage/infrastructure.html#decoded-as-utf-8,-with-error-handling

// Adds a decoding error to the parser's error list, based on the current state
// of the Utf8Iterator.
static void add_error(Utf8Iterator* iter, GumboErrorType type) {
  GumboParser* parser = iter->_parser;

  GumboError* error = gumbo_add_error(parser);
  if (!error) {
    return;
  }
  error->type = type;
  error->position = iter->_pos;
  error->original_text = iter->_start;

  // At the point the error is recorded, the code point hasn't been computed
  // yet (and can't be, because it's invalid), so we need to build up the raw
  // hex value from the bytes under the cursor.
  uint64_t code_point = 0;
  for (int i = 0; i < iter->_width; ++i) {
    code_point = (code_point << 8) | (unsigned char) iter->_start[i];
  }
  error->v.codepoint = code_point;
}

// Reads the next UTF-8 character in the iter.
// This assumes that iter->_start points to the beginning of the character.
// When this method returns, iter->_width and iter->_current will be set
// appropriately, as well as any error flags.
static void read_char(Utf8Iterator* iter) {
  unsigned char c;
  unsigned char mask = '\0';
  int is_bad_char = false;

  c = (unsigned char) *iter->_start;
  if (c < 0x80) {
    // Valid one-byte sequence.
    iter->_width = 1;
    mask = 0xFF;
  } else if (c < 0xC0) {
    // Continuation character not following a multibyte sequence.
    // The HTML5 spec here says to consume the byte and output a replacement
    // character.
    iter->_width = 1;
    is_bad_char = true;
  } else if (c < 0xE0) {
    iter->_width = 2;
    mask = 0x1F;                // 00011111 in binary.
    if (c < 0xC2) {
      // Overlong encoding; error according to UTF8/HTML5 spec.
      is_bad_char = true;
    }
  } else if (c < 0xF0) {
    iter->_width = 3;
    mask = 0xF;                 // 00001111 in binary.
  } else if (c < 0xF5) {
    iter->_width = 4;
    mask = 0x7;                 // 00000111 in binary.
  } else if (c < 0xF8) {
    // The following cases are all errors, but we need to handle them separately
    // so that we consume the proper number of bytes from the input stream
    // before replacing them with the replacement char.  The HTML5 spec
    // specifies that we should consume the shorter of the length specified by
    // the first bit or the run leading up to the first non-continuation
    // character.
    iter->_width = 5;
    is_bad_char = true;
  } else if (c < 0xFC) {
    iter->_width = 6;
    is_bad_char = true;
  } else if (c < 0xFE) {
    iter->_width = 7;
    is_bad_char = true;
  } else {
    iter->_width = 1;
    is_bad_char = true;
  }

  // Check to make sure we have enough bytes left in the iter to read all that
  // we want.  If not, we set the iter_truncated flag, mark this as a bad
  // character, and adjust the current width so that it consumes the rest of the
  // iter.
  uint64_t code_point = c & mask;
  if (iter->_start + iter->_width > iter->_end) {
    iter->_width = iter->_end - iter->_start;
    add_error(iter, GUMBO_ERR_UTF8_TRUNCATED);
    is_bad_char = true;
  }

  // Now we decode continuation bytes, shift them appropriately, and build up
  // the appropriate code point.
  assert(iter->_width < 8);
  for (int i = 1; i < iter->_width; ++i) {
    c = (unsigned char) iter->_start[i];
    if (c < 0x80 || c > 0xBF) {
      // Per HTML5 spec, we don't include the invalid continuation char in the
      // run that we consume here.
      iter->_width = i;
      is_bad_char = true;
      break;
    }
    code_point = (code_point << 6) | (c & ~0x80);
  }
  if (code_point > 0x10FFFF) is_bad_char = true;

  // If we had a decode error, set the current code point to the replacement
  // character and flip the flag indicating that a decode error occurred.
  // Ditto if we have a code point that is explicitly on the list of characters
  // prohibited by the HTML5 spec, such as control characters.
  if (is_bad_char || utf8_is_invalid_code_point(code_point)) {
    add_error(iter, GUMBO_ERR_UTF8_INVALID);
    code_point = kUtf8ReplacementChar;
  }

  // This is the special handling for carriage returns that is mandated by the
  // HTML5 spec.  Since we're looking for particular 7-bit literal characters,
  // we operate in terms of chars and only need a check for iter overrun,
  // instead of having to read in a full next code point.
  // http://www.whatwg.org/specs/web-apps/current-work/multipage/parsing.html#preprocessing-the-input-stream
  if (code_point == '\r') {
    const char* next = iter->_start + iter->_width;
    if (next < iter->_end && *next == '\n') {
      // Advance the iter, as if the carriage return didn't exist.
      ++iter->_start;
      // Preserve the true offset, since other tools that look at it may be
      // unaware of HTML5's rules for converting \r into \n.
      ++iter->_pos.offset;
    }
    code_point = '\n';
  }

  // At this point, we know we have a valid character as the code point, so we
  // set it, and we're done.
  iter->_current = code_point;
}

static void update_position(Utf8Iterator* iter) {
  iter->_pos.offset += iter->_width;
  if (iter->_current == '\n') {
    ++iter->_pos.line;
    iter->_pos.column = 1;
  } else if(iter->_current == '\t') {
    int tab_stop = iter->_parser->_options->tab_stop;
    iter->_pos.column = ((iter->_pos.column / tab_stop) + 1) * tab_stop;
  } else {
    ++iter->_pos.column;
  }
}

// Returns true if this Unicode code point is in the list of characters
// forbidden by the HTML5 spec, such as undefined control chars.
bool utf8_is_invalid_code_point(int c) {
  return (c >= 0x1 && c <= 0x8) || c == 0xB || (c >= 0xE && c <= 0x1F) ||
      (c >= 0x7F && c <= 0x9F) || (c >= 0xFDD0 && c <= 0xFDEF) ||
      ((c & 0xFFFF) == 0xFFFE) || ((c & 0xFFFF) == 0xFFFF);
}

void utf8iterator_init(
    GumboParser* parser, const char* source, size_t source_length,
    Utf8Iterator* iter) {
  iter->_start = source;
  iter->_end = source + source_length;
  iter->_width = 0;
  iter->_pos.line = 1;
  iter->_pos.column = 1;
  iter->_pos.offset = 0;
  iter->_parser = parser;
  if (source_length) {
    read_char(iter);
  } else {
    iter->_current = -1;
  }
}

void utf8iterator_next(Utf8Iterator* iter) {
  if (iter->_current == -1) {
    // If we're already at EOF, bail out before advancing anything to avoid
    // reading past the end of the buffer.  It's easier to catch this case here
    // than litter the code with lots of individual checks for EOF.
    return;
  }
  iter->_start += iter->_width;
  // We update positions based on the *last* character read, so that the first
  // character following a newline is at column 1 in the next line.
  update_position(iter);
  if (iter->_start < iter->_end) {
    read_char(iter);
  } else {  // EOF
    iter->_current = -1;
  }
}

int utf8iterator_current(const Utf8Iterator* iter) {
  return iter->_current;
}

void utf8iterator_get_position(
    const Utf8Iterator* iter, GumboSourcePosition* output) {
  *output = iter->_pos;
}

const char* utf8iterator_get_char_pointer(const Utf8Iterator* iter) {
  return iter->_start;
}

bool utf8iterator_maybe_consume_match(
    Utf8Iterator* iter, const char* prefix, size_t length,
    bool case_sensitive) {
  bool matched = (iter->_start + length <= iter->_end) && (case_sensitive ?
      !strncmp(iter->_start, prefix, length) :
      !strncasecmp(iter->_start, prefix, length));
  if (matched) {
    for (int i = 0; i < length; ++i) {
      utf8iterator_next(iter);
    }
    return true;
  } else {
    return false;
  }
}

void utf8iterator_mark(Utf8Iterator* iter) {
  iter->_mark = iter->_start;
  iter->_mark_pos = iter->_pos;
}

// Returns the current input stream position to the mark.
void utf8iterator_reset(Utf8Iterator* iter) {
  iter->_start = iter->_mark;
  iter->_pos = iter->_mark_pos;
  read_char(iter);
}

// Sets the position and original text fields of an error to the value at the
// mark.
void utf8iterator_fill_error_at_mark(
    Utf8Iterator* iter, GumboError* error) {
  error->position = iter->_mark_pos;
  error->original_text = iter->_mark;
}
