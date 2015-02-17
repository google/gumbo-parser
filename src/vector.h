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

#ifndef GUMBO_VECTOR_H_
#define GUMBO_VECTOR_H_

#include "gumbo.h"

#ifdef __cplusplus
extern "C" {
#endif

// Initializes a new GumboVector with the specified initial capacity.
void gumbo_vector_init(size_t initial_capacity, GumboVector* vector);

// Frees the memory used by an GumboVector.  Does not free the contained
// pointers.
void gumbo_vector_destroy(GumboVector* vector);

// Adds a new element to an GumboVector.
void gumbo_vector_add(void* element, GumboVector* vector);

// Removes and returns the element most recently added to the GumboVector.
// Ownership is transferred to caller.  Capacity is unchanged.  If the vector is
// empty, NULL is returned.
void* gumbo_vector_pop(GumboVector* vector);

// Inserts an element at a specific index.  This is potentially O(N) time, but
// is necessary for some of the spec's behavior.
void gumbo_vector_insert_at(void* element, int index, GumboVector* vector);

// Removes an element from the vector, or does nothing if the element is not in
// the vector.
void gumbo_vector_remove(const void* element, GumboVector* vector);

// Removes and returns an element at a specific index.  Note that this is
// potentially O(N) time and should be used sparingly.
void* gumbo_vector_remove_at(int index, GumboVector* vector);

int gumbo_vector_index_of(GumboVector* vector, const void* element);

void gumbo_vector_splice(
	int where, int n_to_remove, void **data, int n_to_insert, GumboVector* vector);

#ifdef __cplusplus
}
#endif

#endif  // GUMBO_VECTOR_H_
