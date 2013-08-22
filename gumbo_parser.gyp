# Copyright 2013 The Chromium Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

{
  'targets': [
    {
      'target_name': 'gumbo_parser',
      'type': 'static_library',
      'sources': [
        'src/attribute.c',
        'src/attribute.h',
        'src/char_ref.c',
        'src/char_ref.h',
        'src/error.c',
        'src/error.h',
        'src/gumbo.h',
        'src/insertion_mode.h',
        'src/parser.c',
        'src/parser.h',
        'src/string_buffer.c',
        'src/string_buffer.h',
        'src/string_piece.c',
        'src/string_piece.h',
        'src/tag.c',
        'src/token_type.h',
        'src/tokenizer.c',
        'src/tokenizer.h',
        'src/tokenizer_states.h',
        'src/utf8.c',
        'src/utf8.h',
        'src/util.c',
        'src/util.h',
        'src/vector.c',
        'src/vector.h',
      ],
    },
  ],
}
