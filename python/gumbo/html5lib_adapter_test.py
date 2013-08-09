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
"""Tests for the Gumbo => Html5lib adapter."""
import os
import StringIO
import warnings

from html5lib.tests import support
from html5lib.tests import test_parser

import unittest
import html5lib_adapter


class Html5libAdapterTest(unittest.TestCase):
  """Adapter between Gumbo and the html5lib tests.

  This works through a bit of magic.  It's an empty class at first, but then
  buildTestCases runs through the test files in html5lib, and adds a
  method to this class for each one.  That method acts like
  test_parser.TestCase.runParserTest, running a parse, serializing the tree, and
  comparing it to the expected output.
  """
  def parser_test(self, inner_html, input, expected, errors, tree_cls):
    p = html5lib_adapter.HTMLParser(tree=tree_cls(namespaceHTMLElements=True))
    if not inner_html:
      # TODO(jdtang): Need to implement fragment parsing.
      document = p.parse(StringIO.StringIO(input))
    else:
      return

    with warnings.catch_warnings():
      # Etree serializer in html5lib uses a deprecated getchildren() API.
      warnings.filterwarnings('ignore', category=DeprecationWarning)
      output = test_parser.convertTreeDump(p.tree.testSerializer(document))

    expected = test_parser.namespaceExpected(
        r'\1<html \2>', test_parser.convertExpected(expected))

    error_msg = '\n'.join(['\n\nInput:', input, '\nExpected:', expected,
                           '\nReceived:', output])
    self.assertEquals(expected, output,
                      error_msg.encode('ascii', 'xmlcharrefreplace') + '\n')
    # TODO(jdtang): Check error messages, when there's full error support.

  def testHtmlStructure(self):
    p = html5lib_adapter.HTMLParser(
        tree=test_parser.treeTypes['simpletree'](namespaceHTMLElements=True))
    document = p.parse(StringIO.StringIO('<!DOCTYPE>Hello'))
    self.assertEquals(1, document.type)
    self.assertEquals(2, len(document.childNodes))

    doctype = document.childNodes[0]
    self.assertEquals(3, doctype.type)

    root = document.childNodes[1]
    self.assertEquals(5, root.type)
    self.assertEquals('html', root.name)
    self.assertEquals(2, len(root.childNodes))

    head = root.childNodes[0]
    self.assertEquals('head', head.name)
    self.assertEquals(0, len(head.attributes))
    self.assertEquals(0, len(head.childNodes))

    body = root.childNodes[1]
    self.assertEquals('body', body.name)
    self.assertEquals(0, len(body.attributes))
    self.assertEquals(1, len(body.childNodes))

    hello = body.childNodes[0]
    self.assertEquals(4, hello.type)
    self.assertEquals('Hello', hello.value)


def BuildTestCases(cls):
  for filename in support.html5lib_test_files('tree-construction'):
    test_name = os.path.basename(filename).replace('.dat', '')
    for i, test in enumerate(support.TestData(filename, 'data')):
      for tree_name, tree_cls in test_parser.treeTypes.items():
        # html5lib parses <noscript> tags as if the scripting-enabled flag is
        # set, while we parse as if the scripting-disabled flag is set (since we
        # don't really support scripting and the resulting parse tree is often
        # more useful for toolsmiths).  That means our output will differ by
        # design from html5lib's, so we disable any of their tests that involve
        # <noscript>
        if '<noscript>' in test['data']:
          continue

        def test_func(
            self,
            inner_html=test['document-fragment'],
            input=test['data'],
            expected=test['document'],
            errors=test.get('errors', '').split('\n'),
            tree_cls=tree_cls):
          return self.parser_test(inner_html, input, expected, errors, tree_cls)
        test_func.__name__ = 'test_%s_%d_%s' % (test_name, i + 1, tree_name)
        setattr(cls, test_func.__name__, test_func)


if __name__ == '__main__':
  BuildTestCases(Html5libAdapterTest)
  unittest.main()
