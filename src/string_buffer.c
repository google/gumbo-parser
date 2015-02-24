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

#include "string_buffer.h"

#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#include "arena.h"
#include "string_piece.h"
#include "util.h"

struct GumboInternalParser;

// Size chosen via statistical analysis of ~60K websites.
// 99% of text nodes and 98% of attribute names/values fit within 5 characters.
// Since the arena allocator only ever returns word-aligned chunks, however, it
// makes no sense to use less than 8 chars.
static const size_t kDefaultStringBufferSize = 8;

static bool maybe_resize_string_buffer(
    struct GumboInternalParser* parser, size_t additional_chars,
    GumboStringBuffer* buffer) {
  size_t new_length = buffer->length + additional_chars;
  size_t new_capacity = buffer->capacity;
  while (new_capacity < new_length) {
    new_capacity *= 2;
  }
  if (new_capacity != buffer->capacity) {
    if (new_capacity > ARENA_CHUNK_SIZE) {
      if (buffer->capacity == ARENA_CHUNK_SIZE) {
        // If we have already resized the buffer to the maximum chunk size, then
        // we're out of memory, and we ignore any more writes to the buffer.
        gumbo_set_out_of_memory(parser);
        return false;
      }
      // Otherwise, this is the first time we've hit the new max.  Resize the
      // allocation to take up a whole chunk, but don't set an error condition
      // and let writes proceed.
      new_capacity = ARENA_CHUNK_SIZE;
    }
    char* new_data = gumbo_parser_allocate(parser, new_capacity);
    memcpy(new_data, buffer->data, buffer->length);
    gumbo_parser_deallocate(parser, buffer->data);
    buffer->data = new_data;
    buffer->capacity = new_capacity;
  }
  return true;
}

#define ENSURE_CAPACITY_OR_RETURN(capacity, buffer) \
  if (!maybe_resize_string_buffer(parser, (capacity), (buffer))) { return; }

void gumbo_string_buffer_init(
    struct GumboInternalParser* parser, GumboStringBuffer* output) {
  output->data = gumbo_parser_allocate(parser, kDefaultStringBufferSize);
  output->length = 0;
  output->capacity = kDefaultStringBufferSize;
}

bool gumbo_string_buffer_reserve(
    struct GumboInternalParser* parser, size_t min_capacity,
    GumboStringBuffer* output) {
  return maybe_resize_string_buffer(
      parser, min_capacity - output->length, output);
}

void gumbo_string_buffer_append_codepoint(
    struct GumboInternalParser* parser, int c, GumboStringBuffer* output) {
  // num_bytes is actually the number of continuation bytes, 1 less than the
  // total number of bytes.  This is done to keep the loop below simple and
  // should probably change if we unroll it.
  int num_bytes, prefix;
  if (c <= 0x7f) {
    num_bytes = 0;
    prefix = 0;
  } else if (c <= 0x7ff) {
    num_bytes = 1;
    prefix = 0xc0;
  } else if (c <= 0xffff) {
    num_bytes = 2;
    prefix = 0xe0;
  } else {
    num_bytes = 3;
    prefix = 0xf0;
  }
  ENSURE_CAPACITY_OR_RETURN(num_bytes + 1, output);
  output->data[output->length++] = prefix | (c >> (num_bytes * 6));
  for (int i = num_bytes - 1; i >= 0; --i) {
    output->data[output->length++] = 0x80 | (0x3f & (c >> (i * 6)));
  }
}

void gumbo_string_buffer_append_string(
    struct GumboInternalParser* parser, GumboStringPiece* str,
    GumboStringBuffer* output) {
  ENSURE_CAPACITY_OR_RETURN(str->length, output);
  memcpy(output->data + output->length, str->data, str->length);
  output->length += str->length;
}

char* gumbo_string_buffer_to_string(
    struct GumboInternalParser* parser, GumboStringBuffer* input) {
  char* buffer;
  if (maybe_resize_string_buffer(parser, input->length + 1, input)) {
    buffer = input->data;
    buffer[input->length] = '\0';
  } else {
    // Out of memory: replace the last character.
    buffer = input->data;
    buffer[input->length - 1] = '\0';
  }
  gumbo_string_buffer_init(parser, input);
  return buffer;
}

void gumbo_string_buffer_clear(
    struct GumboInternalParser* parser, GumboStringBuffer* input) {
  input->length = 0;
  if (input->capacity > kDefaultStringBufferSize * 8) {
    // This approach to clearing means that the buffer can grow unbounded and
    // tie up memory that may be needed for parsing the rest of the document, so
    // we free and reinitialize the buffer if its grown more than 3 doublings.
    gumbo_string_buffer_destroy(parser, input);
    gumbo_string_buffer_init(parser, input);
  }
}

void gumbo_string_buffer_destroy(
    struct GumboInternalParser* parser, GumboStringBuffer* buffer) {
  gumbo_parser_deallocate(parser, buffer->data);
}
