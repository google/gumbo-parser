#ifndef STRING_UTIL_H
#define STRING_UTIL_H

#if defined(_WIN32) || defined(_WIN64)
#  define strcasecmp _stricmp
#  define strncasecmp _strnicmp
#else
#include <strings.h>
#endif

#endif // STRING_UTIL_H
