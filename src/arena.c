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

void arena_init(GumboArena* arena) {
  assert(arena != NULL);
  arena->head = malloc(sizeof(GumboArenaChunk));
  arena->head->next = NULL;
  arena->allocation_ptr = arena->head->data;
  gumbo_debug("Initializing arena @%x\n", arena->head);
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

void* gumbo_arena_malloc(void* userdata, size_t size) {
  GumboArena* arena = userdata;
  GumboArenaChunk* current_chunk = arena->head;
  if (arena->allocation_ptr >= current_chunk->data + CHUNK_SIZE - size) {
    GumboArenaChunk* new_chunk = malloc(sizeof(GumboArenaChunk));
    gumbo_debug("Allocating new arena chunk @%x\n", new_chunk);
    new_chunk->next = current_chunk;
    arena->head = new_chunk;
    arena->allocation_ptr = new_chunk->data;
  }
  void* obj = arena->allocation_ptr;
  arena->allocation_ptr += (size + ALIGNMENT - 1) & ~(ALIGNMENT - 1);
  return obj;
}

void arena_free(void* userdata, void* obj) {
  // No-op.
}

