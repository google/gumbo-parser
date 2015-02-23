// Copyright 2015 Jonathan Tang. All Rights Reserved.
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
// Author: jonathan.d.tang@gmail.com (Jonathan Tang)

#ifndef GUMBO_ARENA_H_
#define GUMBO_ARENA_H_

#include "gumbo.h"

#ifdef __cplusplus
extern "C" {
#endif

// 400K is right around the median total memory allocation (on a corpus of ~60K
// webpages taken from CommonCrawl), and allows up to 50K 8-byte allocations.
// The 95th percentile is roughly 2M, which would give 5 arena chunks.
// This should allow ~50% of webpages to parse in a single arena chunk, and the
// vast majority to use no more than 5, while still keeping typical memory usage
// well under a meg.
#define CHUNK_SIZE 400000
#define ALIGNMENT 8

typedef struct GumboInternalArenaChunk {
  struct GumboInternalArenaChunk* next;
  char data[CHUNK_SIZE];
} GumboArenaChunk;

// Initialize an arena, allocating the first chunk for it.
void arena_init(GumboArena* arena);

// Destroy an arena, freeing all memory used by it and all objects contained.
void arena_destroy(GumboArena* arena);

// gumbo_arena_malloc is defined in gumbo.h

// No-op free function for use as a custom allocator.
void arena_free(void* arena, void* obj);

#ifdef __cplusplus
}
#endif

#endif  // GUMBO_ARENA_H_
