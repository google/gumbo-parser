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

typedef struct GumboInternalArenaChunk {
  struct GumboInternalArenaChunk* next;
  char data[];
} GumboArenaChunk;

// Initialize an arena, allocating the first chunk for it.
void arena_init(GumboArena* arena, size_t chunk_size);

// Destroy an arena, freeing all memory used by it and all objects contained.
void arena_destroy(GumboArena* arena);

// Allocate an object in an arena.  chunk_size must remain constant between
// allocations.  Returns NULL if either the program requests size > chunk_size
// or the system malloc fails.
void* arena_malloc(GumboArena* arena, size_t chunk_size, size_t size);

// No-op free function for use as a custom allocator.
void arena_free(void* arena, void* obj);

#ifdef __cplusplus
}
#endif

#endif  // GUMBO_ARENA_H_
