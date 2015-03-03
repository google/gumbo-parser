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

#include "arena.h"

#include <assert.h>
#include <stdlib.h>

#include "util.h"

unsigned int gChunksAllocated;

// Alignment of each returned allocation block.  We make sure everything is
// pointer-aligned.
#define ARENA_ALIGNMENT (sizeof(void*))

// Size of a single arena chunk.  Most recent Intel CPUs have a 256K L2 cache
// on-core, so we try to size a chunk to fit in that with a little extra room
// for the stack.  Measurements on a corpus of ~60K webpages indicate that
// ...
#define ARENA_CHUNK_SIZE 240000

typedef struct GumboInternalArenaChunk {
  struct GumboInternalArenaChunk* next;
  char data[ARENA_CHUNK_SIZE];
} GumboArenaChunk;

void arena_init(GumboArena* arena) {
  assert(arena != NULL);
  arena->head = malloc(sizeof(GumboArenaChunk));
  arena->head->next = NULL;
  arena->allocation_ptr = arena->head->data;
  gumbo_debug("Initializing arena @%x\n", arena->head);
  gChunksAllocated = 1;
}

void arena_destroy(GumboArena* arena) {
  GumboArenaChunk* chunk = arena->head;
  while (chunk) {
    gumbo_debug("Freeing arena chunk @%x\n", chunk);
    GumboArenaChunk* to_free = chunk;
    chunk = chunk->next;
    free(to_free);
  }
}

static void* allocate_new_chunk(GumboArena* arena, size_t size) {
  GumboArenaChunk* new_chunk = malloc(size);
  gumbo_debug("Allocating new arena chunk of size %d @%x\n", size, new_chunk);
  if (!new_chunk) {
    gumbo_debug("Malloc failed.\n");
    return NULL;
  }
  ++gChunksAllocated;
  new_chunk->next = arena->head;
  arena->head = new_chunk;
  return new_chunk->data;
}

void* arena_malloc(GumboArena* arena, size_t size) {
  size_t aligned_size = (size + ARENA_ALIGNMENT - 1) & ~(ARENA_ALIGNMENT - 1);
  if (arena->allocation_ptr >=
      arena->head->data + ARENA_CHUNK_SIZE - aligned_size) {
    if (size > ARENA_CHUNK_SIZE) {
      // Big block requested; we allocate a chunk of memory of the requested
      // size, add it to the list, and then immediately allocate another one.
      gumbo_debug(
          "Allocation size %d exceeds chunk size %d", size, ARENA_CHUNK_SIZE);
      size_t total_chunk_size =
        size + sizeof(GumboArenaChunk) - ARENA_CHUNK_SIZE;
      void* result = allocate_new_chunk(arena, total_chunk_size);
      arena->allocation_ptr =
          allocate_new_chunk(arena, sizeof(GumboArenaChunk));
      return result;
    }
    // Normal operation: allocate the default arena chunk size.
    arena->allocation_ptr = allocate_new_chunk(arena, sizeof(GumboArenaChunk));
  }
  void* obj = arena->allocation_ptr;
  arena->allocation_ptr += aligned_size;
  assert(arena->allocation_ptr <= arena->head->data + ARENA_CHUNK_SIZE);
  return obj;
}

unsigned int gumbo_arena_chunks_allocated() {
  return gChunksAllocated;
}

void arena_free(void* userdata, void* obj) {
  // No-op.
}

