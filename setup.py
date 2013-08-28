#!/usr/bin/env python
from setuptools import setup

def readme():
  with open('README.md') as f:
    return f.read()

setup(name='gumbo',
      version='{{VERSION}}',
      description='Python bindings for Gumbo HTML parser',
      long_description=readme(),
      url='http://github.com/google/gumbo-parser',
      keywords='gumbo html html5 parser google html5lib beautifulsoup',
      author='Jonathan Tang',
      author_email='jdtang@google.com',
      license='Apache 2.0',
      packages=['gumbo'],
      package_dir={'': 'python'},
      zip_safe=True)
