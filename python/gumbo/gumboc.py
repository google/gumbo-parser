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

"""CTypes bindings for the Gumbo HTML5 parser.

This exports the raw interface of the library as a set of very thin ctypes
wrappers.  It's intended to be wrapped by other libraries to provide a more
Pythonic API.
"""

__author__ = 'jdtang@google.com (Jonathan Tang)'

import contextlib
import ctypes


try:
  _dll = ctypes.cdll.LoadLibrary('libgumbo.so')
except OSError:
  # MacOS X
  _dll = ctypes.cdll.LoadLibrary('libgumbo.dylib')

# Some aliases for common types.
_bitvector = ctypes.c_uint
_Ptr = ctypes.POINTER


class Enum(ctypes.c_uint):
  class __metaclass__(type(ctypes.c_uint)):
    def __new__(metaclass, name, bases, cls_dict):
      cls = type(ctypes.c_uint).__new__(metaclass, name, bases, cls_dict)
      if name == 'Enum':
        return cls
      try:
        for i, value in enumerate(cls_dict['_values_']):
          setattr(cls, value, cls.from_param(i))
      except KeyError:
        raise ValueError('No _values_ list found inside enum type.')
      except TypeError:
        raise ValueError('_values_ must be a list of names of enum constants.')
      return cls

  @classmethod
  def from_param(cls, param):
    if isinstance(param, Enum):
      if param.__class__ != cls:
        raise ValueError("Can't mix enums of different types")
      return param
    if param < 0 or param > len(cls._values_):
      raise ValueError('%d is out of range for enum type %s; max %d.' %
                       (param, cls.__name__, len(cls._values_)))
    return cls(param)

  def __eq__(self, other):
    return self.value == other.value

  def __ne__(self, other):
    return self.value != other.value

  def __hash__(self):
    return hash(self.value)

  def __repr__(self):
    try:
      return self._values_[self.value]
    except IndexError:
      raise IndexError('Value %d is out of range for %r' %
                       (self.value, self._values_))


class StringPiece(ctypes.Structure):
  _fields_ = [
      ('data', _Ptr(ctypes.c_char)),
      ('length', ctypes.c_size_t),
      ]

  def __len__(self):
    return self.length

  def __str__(self):
    return ctypes.string_at(self.data, self.length)


class SourcePosition(ctypes.Structure):
  _fields_ = [
      ('line', ctypes.c_uint),
      ('column', ctypes.c_uint),
      ('offset', ctypes.c_uint)
      ]
SourcePosition.EMPTY = SourcePosition.in_dll(_dll, 'kGumboEmptySourcePosition')


class AttributeNamespace(Enum):
  URLS = [
      'http://www.w3.org/1999/xhtml',
      'http://www.w3.org/1999/xlink',
      'http://www.w3.org/XML/1998/namespace',
      'http://www.w3.org/2000/xmlns',
  ]
  _values_ = ['NONE', 'XLINK', 'XML', 'XMLNS']

  def to_url(self):
    return self.URLS[self.value]


class Attribute(ctypes.Structure):
  _fields_ = [
      ('namespace', AttributeNamespace),
      ('name', ctypes.c_char_p),
      ('original_name', StringPiece),
      ('value', ctypes.c_char_p),
      ('original_value', StringPiece),
      ('name_start', SourcePosition),
      ('name_end', SourcePosition),
      ('value_start', SourcePosition),
      ('value_end', SourcePosition)
      ]


class Vector(ctypes.Structure):
  _type_ = ctypes.c_void_p
  _fields_ = [
      ('data', _Ptr(ctypes.c_void_p)),
      ('length', ctypes.c_uint),
      ('capacity', ctypes.c_uint)
      ]

  class Iter(object):
    def __init__(self, vector):
      self.current = 0
      self.vector = vector

    def __iter__(self):
      return self

    def next(self):
      if self.current >= self.vector.length:
        raise StopIteration
      obj = self.vector[self.current]
      self.current += 1
      return obj

  def __len__(self):
    return self.length

  def __getitem__(self, i):
    if isinstance(i, (int, long)):
      if i < 0:
        i += self.length
      if i > self.length:
        raise IndexError
      array_type = _Ptr(_Ptr(self._type_))
      return ctypes.cast(self.data, array_type)[i].contents
    return list(self)[i]

  def __iter__(self):
    return Vector.Iter(self)


Vector.EMPTY = Vector.in_dll(_dll, 'kGumboEmptyVector')


class AttributeVector(Vector):
  _type_ = Attribute


class NodeVector(Vector):
  # _type_ assigned later, to avoid circular references with Node
  pass


class QuirksMode(Enum):
  _values_ = ['NO_QUIRKS', 'QUIRKS', 'LIMITED_QUIRKS']


class Document(ctypes.Structure):
  _fields_ = [
      ('children', NodeVector),
      ('has_doctype', ctypes.c_bool),
      ('name', ctypes.c_char_p),
      ('public_identifier', ctypes.c_char_p),
      ('system_identifier', ctypes.c_char_p),
      ('doc_type_quirks_mode', QuirksMode),
      ]

  def __repr__(self):
    return 'Document'


class Namespace(Enum):
  URLS = [
      'http://www.w3.org/1999/xhtml',
      'http://www.w3.org/2000/svg',
      'http://www.w3.org/1998/Math/MathML',
  ]
  _values_ = ['HTML', 'SVG', 'MATHML']

  def to_url(self):
    return self.URLS[self.value]


class Tag(Enum):
  _values_ = [
      'HTML',
      'HEAD',
      'TITLE',
      'BASE',
      'LINK',
      'META',
      'STYLE',
      'SCRIPT',
      'NOSCRIPT',
      'BODY',
      'SECTION',
      'NAV',
      'ARTICLE',
      'ASIDE',
      'H1',
      'H2',
      'H3',
      'H4',
      'H5',
      'H6',
      'HGROUP',
      'HEADER',
      'FOOTER',
      'ADDRESS',
      'P',
      'HR',
      'PRE',
      'BLOCKQUOTE',
      'OL',
      'UL',
      'LI',
      'DL',
      'DT',
      'DD',
      'FIGURE',
      'FIGCAPTION',
      'DIV',
      'A',
      'EM',
      'STRONG',
      'SMALL',
      'S',
      'CITE',
      'Q',
      'DFN',
      'ABBR',
      'TIME',
      'CODE',
      'VAR',
      'SAMP',
      'KBD',
      'SUB',
      'SUP',
      'I',
      'B',
      'MARK',
      'RUBY',
      'RT',
      'RP',
      'BDI',
      'BDO',
      'SPAN',
      'BR',
      'WBR',
      'INS',
      'DEL',
      'IMAGE',
      'IMG',
      'IFRAME',
      'EMBED',
      'OBJECT',
      'PARAM',
      'VIDEO',
      'AUDIO',
      'SOURCE',
      'TRACK',
      'CANVAS',
      'MAP',
      'AREA',
      'MATH',
      'MI',
      'MO',
      'MN',
      'MS',
      'MTEXT',
      'MGLYPH',
      'MALIGNMARK',
      'ANNOTATION_XML',
      'SVG',
      'FOREIGNOBJECT',
      'DESC',
      'TABLE',
      'CAPTION',
      'COLGROUP',
      'COL',
      'TBODY',
      'THEAD',
      'TFOOT',
      'TR',
      'TD',
      'TH',
      'FORM',
      'FIELDSET',
      'LEGEND',
      'LABEL',
      'INPUT',
      'BUTTON',
      'SELECT',
      'DATALIST',
      'OPTGROUP',
      'OPTION',
      'TEXTAREA',
      'KEYGEN',
      'OUTPUT',
      'PROGRESS',
      'METER',
      'DETAILS',
      'SUMMARY',
      'COMMAND',
      'MENU',
      'APPLET',
      'ACRONYM',
      'BGSOUND',
      'DIR',
      'FRAME',
      'FRAMESET',
      'NOFRAMES',
      'ISINDEX',
      'LISTING',
      'XMP',
      'NEXTID',
      'NOEMBED',
      'PLAINTEXT',
      'RB',
      'STRIKE',
      'BASEFONT',
      'BIG',
      'BLINK',
      'CENTER',
      'FONT',
      'MARQUEE',
      'MULTICOL',
      'NOBR',
      'SPACER',
      'TT',
      'U',
      'UNKNOWN',
      ]


class Element(ctypes.Structure):
  _fields_ = [
      ('children', NodeVector),
      ('tag', Tag),
      ('tag_namespace', Namespace),
      ('original_tag', StringPiece),
      ('original_end_tag', StringPiece),
      ('start_pos', SourcePosition),
      ('end_pos', SourcePosition),
      ('attributes', AttributeVector),
      ]

  @property
  def tag_name(self):
    original_tag = StringPiece.from_buffer_copy(self.original_tag)
    _tag_from_original_text(ctypes.byref(original_tag))
    if self.tag_namespace == Namespace.SVG:
      svg_tagname = _normalize_svg_tagname(ctypes.byref(original_tag))
      if svg_tagname is not None:
        return str(svg_tagname)
    if self.tag == Tag.UNKNOWN:
      if original_tag.data is None:
        return ''
      return str(original_tag).lower()
    return _tagname(self.tag)

  def __repr__(self):
    return ('<%r>\n' % self.tag +
            '\n'.join(repr(child) for child in self.children) +
            '</%r>' % self.tag)


class Text(ctypes.Structure):
  _fields_ = [
      ('text', ctypes.c_char_p),
      ('original_text', StringPiece),
      ('start_pos', SourcePosition)
      ]

  def __repr__(self):
    return 'Text(%r)' % self.text


class NodeType(Enum):
  _values_ = ['DOCUMENT', 'ELEMENT', 'TEXT', 'CDATA', 'COMMENT', 'WHITESPACE']


class NodeUnion(ctypes.Union):
  _fields_ = [
      ('document', Document),
      ('element', Element),
      ('text', Text),
      ]


class Node(ctypes.Structure):
  # _fields_ set later to avoid a circular reference

  @property
  def contents(self):
    if self.type == NodeType.DOCUMENT:
      return self.v.document
    elif self.type == NodeType.ELEMENT:
      return self.v.element
    else:
      return self.v.text

  def __getattr__(self, name):
    return getattr(self.contents, name)

  def __setattr__(self, name, value):
    return setattr(self.contents, name, value)

  def __repr__(self):
    return repr(self.contents)


Node._fields_ = [
    ('type', NodeType),
    # Set the type to Node later to avoid a circular dependency.
    ('parent', _Ptr(Node)),
    ('index_within_parent', ctypes.c_size_t),
    # TODO(jdtang): Make a real list of enum constants for this.
    ('parse_flags', _bitvector),
    ('v', NodeUnion)
    ]
NodeVector._type_ = Node


class Options(ctypes.Structure):
  _fields_ = [
      # TODO(jdtang): Allow the Python API to set the allocator/deallocator
      # function.  Right now these are treated as opaque void pointers.
      ('allocator', ctypes.c_void_p),
      ('deallocator', ctypes.c_void_p),
      ('tab_stop', ctypes.c_int),
      ('stop_on_first_error', ctypes.c_bool),
      ('max_utf8_decode_errors', ctypes.c_int),
      # The following two options will likely be removed from the C API, and
      # should be removed from the Python API when that happens too.
      ('verbatim_mode', ctypes.c_bool),
      ('preserve_entities', ctypes.c_bool),
      ]


class Output(ctypes.Structure):
  _fields_ = [
      ('document', _Ptr(Node)),
      ('root', _Ptr(Node)),
      # TODO(jdtang): Error type.
      ('errors', Vector),
      ]


@contextlib.contextmanager
def parse(text, **kwargs):
  options = Options()
  for field_name, _ in Options._fields_:
    try:
      setattr(options, field_name, kwargs[field_name])
    except KeyError:
      setattr(options, field_name, getattr(_DEFAULT_OPTIONS, field_name))
  # We have to manually take a reference to the input text here so that it
  # outlives the parse output.  If we let ctypes do it automatically on function
  # call, it creates a temporary buffer which is destroyed when the call
  # completes, and then the original_text pointers point into invalid memory.
  text_ptr = ctypes.c_char_p(text)
  output = _parse_with_options(ctypes.byref(options), text_ptr, len(text))
  try:
    yield output
  finally:
    _destroy_output(ctypes.byref(options), output)

_DEFAULT_OPTIONS = Options.in_dll(_dll, 'kGumboDefaultOptions')

_parse_with_options = _dll.gumbo_parse_with_options
_parse_with_options.argtypes = [_Ptr(Options), ctypes.c_char_p, ctypes.c_size_t]
_parse_with_options.restype = _Ptr(Output)

_tag_from_original_text = _dll.gumbo_tag_from_original_text
_tag_from_original_text.argtypes = [_Ptr(StringPiece)]
_tag_from_original_text.restype = None

_normalize_svg_tagname = _dll.gumbo_normalize_svg_tagname
_normalize_svg_tagname.argtypes = [_Ptr(StringPiece)]
_normalize_svg_tagname.restype = ctypes.c_char_p

_destroy_output = _dll.gumbo_destroy_output
_destroy_output.argtypes = [_Ptr(Options), _Ptr(Output)]
_destroy_output.restype = None

_tagname = _dll.gumbo_normalized_tagname
_tagname.argtypes = [Tag]
_tagname.restype = ctypes.c_char_p

__all__ = ['StringPiece', 'SourcePosition', 'AttributeNamespace', 'Attribute',
           'Vector', 'AttributeVector', 'NodeVector', 'QuirksMode', 'Document',
           'Namespace', 'Tag', 'Element', 'Text', 'NodeType', 'Node',
           'Options', 'Output', 'parse']
