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

#define ARENA_ALIGNMENT 8

void arena_init(GumboArena* arena, size_t chunk_size) {
  assert(arena != NULL);
  arena->head = malloc(chunk_size);
  arena->head->next = NULL;
  arena->allocation_ptr = arena->head->data;
  gumbo_debug(
      "Initializing arena with chunk size %d @%x\n", chunk_size, arena->head);
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

void* arena_malloc(GumboArena* arena, size_t chunk_size, size_t size) {
  GumboArenaChunk* current_chunk = arena->head;
  size_t aligned_size = (size + ARENA_ALIGNMENT - 1) & ~(ARENA_ALIGNMENT - 1);
  if (arena->allocation_ptr >=
      current_chunk->data + chunk_size - aligned_size) {
    if (size > chunk_size) {
      gumbo_debug("Allocation size %d exceeds chunk size %d", size, chunk_size);
      return NULL;
    }
    size_t memory_block_size = chunk_size + sizeof(GumboArenaChunk);
    GumboArenaChunk* new_chunk = malloc(memory_block_size);
    gumbo_debug("Allocating new arena chunk of size %d @%x\n",
        memory_block_size, new_chunk);
    if (!new_chunk) {
      gumbo_debug("Malloc failed.\n");
      return NULL;
    }
    new_chunk->next = current_chunk;
    arena->head = new_chunk;
    arena->allocation_ptr = new_chunk->data;
    ++gChunksAllocated;
  }
  void* obj = arena->allocation_ptr;
  arena->allocation_ptr += aligned_size;
  assert(arena->allocation_ptr <= arena->head->data + chunk_size);
  return obj;
}

unsigned int gumbo_arena_chunks_allocated() {
  return gChunksAllocated;
}

void arena_free(void* userdata, void* obj) {
  // No-op.
}

