Gumbo - A pure-C HTML5 parser.
============
Copyright 2010-2013 Google Inc.
https://github.com/google/gumbo-parser
Version 0.9.0

Installation
============

To build and install the library, issue the standard UNIX incantation from the root of the distribution:

    $ ./configure
    $ make
    $ sudo make install

Gumbo comes with full pkg-config support, so you can use the pkg-config to print the flags needed to link your program against it:

    $ pkg-config --cflags gumbo         # print compiler flags
    $ pkg-config --libs gumbo           # print linker flags
    $ pkg-config --cflags --libs gumbo  # print both

For example:

    $ gcc my_program.c `pkg-config --cflags --libs gumbo`

See the pkg-config man page for more info.

There are a number of sample programs in the examples/ directory.  They're built automatically by 'make', but can also be made individually with 'make <programname>' (eg. 'make clean_text').

To run the unit tests, you'll need to have [googletest](https://code.google.com/p/googletest/) downloaded and unzipped.  The googletest maintainers recommend against using 'make install'; instead, symlink the root googletest directory to 'gtest' inside gumbo's root directory, and then 'make check':

    $ unzip gtest-1.6.0.zip
    $ cd gumbo-*
    $ ln -s ../gtest-1.6.0 gtest
    $ make check

Gumbo's 'make check' has code to automatically configure & build gtest and then link in the library.

Basic Usage
===========

Within your program, you need to include "gumbo.h" and then issue a call to gumbo_parse:

```C++
#include "gumbo.h"

int main(int argc, char** argv) {
  GumboOutput* output = gumbo_parse(argv[1]);
  // Do stuff with output->root
  gumbo_destroy_output(&kGumboDefaultOptions, output);
}
```

See the API documentation and sample programs for more details.

A note on API/ABI compatibility
===============================

We'll make a best effort to preserve API compatibility between releases.  The initial release is a 0.9 (beta) release to solicit comments from early adopters, but if no major problems are found with the API, a 1.0 release will follow shortly, and the API of that should be considered stable.  If changes are necessary, we follow [semantic versioning](http://semver.org).

We make no such guarantees about the ABI, and it's very likely that subsequent versions may require a recompile of client code.  For this reason, we recommend NOT using Gumbo data structures throughout a program, and instead limiting them to a translation layer that picks out whatever data is needed from the parse tree and then converts that to persistent data structures more appropriate for the application.  The API is structured to encourage this use, with a single delete function for the whole parse tree, and is not designed with mutation in mind.

Python usage
============
To install the python bindings, make sure that the C library is installed first, and then "sudo python setup.py install" from the root of the distro.  This install a 'gumbo' module; 'pydoc gumbo' should tell you about them.

Recommended best-practice for Python usage is to use one of the adapters to an existing API (personally, I prefer BeautifulSoup) and write your program in terms of those.  The raw CTypes bindings should be considered building blocks for higher-level libraries and rarely referenced directly.
