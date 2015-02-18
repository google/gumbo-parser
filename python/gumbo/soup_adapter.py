# Copyright 2012 Google Inc. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

"""Adapter between Gumbo and BeautifulSoup.

This parses an HTML document and gives back a BeautifulSoup object, which you
can then manipulate like a normal BeautifulSoup parse tree.
"""

__author__ = 'jdtang@google.com (Jonathan Tang)'

import BeautifulSoup
import ctypes

import gumboc


def _utf8(text):
  return text.decode('utf-8', 'replace')


def _add_source_info(obj, original_text, start_pos, end_pos):
  obj.original = str(original_text)
  obj.line = start_pos.line
  obj.col = start_pos.column
  obj.offset = start_pos.offset
  obj.end_line = end_pos.line
  obj.end_col = end_pos.column
  obj.end_offset = end_pos.offset


def _add_document(element):
  # Currently ignored, since there's no real place for this in the BeautifulSoup
  # API.
  pass


def _add_text(cls):
  return lambda element: cls(_utf8(element.text))


def _convert_attrs(attrs):
  # TODO(jdtang): Ideally attributes would pass along their positions as well,
  # but I can't extend the built in str objects with new attributes.  Maybe work
  # around this with a subclass in some way...
  return [(_utf8(attr.name), _utf8(attr.value)) for attr in attrs]


class _Converter(object):
  def __init__(self, text, **kwargs):
    # We need to record the addresses of GumboNodes as we add them and correlate
    # them with the BeautifulSoup objects that they become.  This lets us
    # correctly wire up the next/previous pointers so that they point to
    # BeautifulSoup objects instead of ctypes ones.
    self._node_map = {}
    self._HANDLERS = [
        _add_document,
        self._add_element,
        _add_text(BeautifulSoup.NavigableString),
        _add_text(BeautifulSoup.CData),
        _add_text(BeautifulSoup.Comment),
        _add_text(BeautifulSoup.NavigableString),
        ]
    self.soup = BeautifulSoup.BeautifulSoup()
    with gumboc.parse(text, **kwargs) as output:
      self.soup.append(self._add_node(output.contents.root.contents))
    
    self._fix_next_prev_pointers(self.soup)

  def _add_element(self, element):
    tag = BeautifulSoup.Tag(
        self.soup, _utf8(element.tag_name), _convert_attrs(element.attributes))
    for child in element.children:
      tag.append(self._add_node(child))
    _add_source_info(
        tag, element.original_tag, element.start_pos, element.end_pos)
    tag.original_end_tag = str(element.original_end_tag)
    return tag

  def _add_node(self, node):
    result = self._HANDLERS[node.type.value](node.contents)

    try:
      result.next_addr = ctypes.addressof(node.next.contents)
    except ValueError:
      # Null pointer.
      result.next_addr = 0

    try:
      result.prev_addr = ctypes.addressof(node.prev.contents)
    except ValueError:
      # Null pointer.
      result.prev_addr = 0

    self._node_map[ctypes.addressof(node.contents)] = result
    return result

  def _fix_next_prev_pointers(self, tag):
    tag.next = self._node_map.get(tag.next_addr)
    tag.prev = self._node_map.get(tag.prev_addr)
    try:
      for child in tag.children:
        self._fix_next_prev_pointers(child)
    except (AttributeError, TypeError):
      # NavigableStrings
      pass


def parse(text, **kwargs):
  converter = _Converter(text, **kwargs)
  return converter.soup
