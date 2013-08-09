#                                               -*- Autoconf -*-
# Process this file with autoconf to produce a configure script.

AC_PREREQ([2.65])
AC_INIT([gumbo], [1.0], [jdtang@google.com])
AC_CONFIG_SRCDIR([src/parser.c])
#AC_CONFIG_HEADERS([config.h])
AC_CONFIG_FILES([Makefile gumbo.pc])

# Checks for programs.
AC_PROG_CXX
AC_PROG_CC

# Checks for libraries.

# Checks for header files.
AC_CHECK_HEADERS([stddef.h stdlib.h string.h strings.h])

# Checks for typedefs, structures, and compiler characteristics.
AC_HEADER_STDBOOL
AC_C_INLINE
AC_TYPE_SIZE_T

# Checks for library functions.
AC_FUNC_MALLOC
AC_CHECK_FUNCS([memmove memset strcasecmp strncasecmp])

# Init Automake & libtool
AM_INIT_AUTOMAKE([foreign subdir-objects])
LT_INIT

AC_OUTPUT
