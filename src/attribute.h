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

#ifndef GUMBO_ATTRIBUTE_H_
#define GUMBO_ATTRIBUTE_H_

#include "gumbo.h"

#ifdef __cplusplus
extern "C" {
#endif

struct GumboInternalParser;

/*
 * Search for a GumboAttribute object in a vector of
 * attributes. Matching is performed case-insensitively
 */
GumboAttribute* gumbo_get_attribute(const GumboVector* attributes, const char* name);

/*
 * Set the "value" of the given GumboAttribute object
 */
void gumbo_set_attribute_value(GumboAttribute *attr, const char *value);

/*
 * Add an attribute to an existing vector of attributes;
 * if the attribute already exists, it will be updated in-place
 */
void gumbo_set_attribute(GumboVector *attributes, const char *name, const char *value);

/*
 * Release the memory used for an GumboAttribute, including the attribute
 * itself.
 */
void gumbo_destroy_attribute(GumboAttribute* attribute);

#ifdef __cplusplus
}
#endif

#endif  // GUMBO_ATTRIBUTE_H_
