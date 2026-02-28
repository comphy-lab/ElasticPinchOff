/**
# params.h

Hyphal-flow style runtime parameter accessors with defaults.
*/

#ifndef PARAMS_H
#define PARAMS_H

#include <ctype.h>
#include <errno.h>
#include <limits.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>

#include "parse_params.h"

static inline bool _param_str_ieq (const char * a, const char * b)
{
  if (!a || !b)
    return false;
  while (*a && *b) {
    if (tolower((unsigned char) *a) != tolower((unsigned char) *b))
      return false;
    a++;
    b++;
  }
  return (*a == '\0' && *b == '\0');
}

static inline void params_init_from_argv (int argc, const char * argv[])
{
  parse_params_init_from_argv(argc, argv);
}

static inline const char * param_string (const char * key,
                                         const char * default_value)
{
  return parse_param_string(key, default_value);
}

static inline double param_double (const char * key, double default_value)
{
  const char * s = param_string(key, NULL);
  if (!s)
    return default_value;

  errno = 0;
  char * end = NULL;
  double value = strtod(s, &end);
  while (end && *end && isspace((unsigned char) *end))
    end++;

  if (errno != 0 || end == s || (end && *end != '\0')) {
    fprintf(stderr,
            "WARNING: Invalid double for '%s' ('%s'), using default %g\n",
            key, s, default_value);
    return default_value;
  }

  return value;
}

static inline int param_int (const char * key, int default_value)
{
  const char * s = param_string(key, NULL);
  if (!s)
    return default_value;

  errno = 0;
  char * end = NULL;
  long value = strtol(s, &end, 10);
  while (end && *end && isspace((unsigned char) *end))
    end++;

  if (errno != 0 || end == s || (end && *end != '\0') ||
      value < INT_MIN || value > INT_MAX) {
    fprintf(stderr,
            "WARNING: Invalid int for '%s' ('%s'), using default %d\n",
            key, s, default_value);
    return default_value;
  }

  return (int) value;
}

static inline bool param_bool (const char * key, bool default_value)
{
  const char * s = param_string(key, NULL);
  if (!s)
    return default_value;

  if (_param_str_ieq(s, "1") || _param_str_ieq(s, "true") ||
      _param_str_ieq(s, "yes") || _param_str_ieq(s, "on"))
    return true;

  if (_param_str_ieq(s, "0") || _param_str_ieq(s, "false") ||
      _param_str_ieq(s, "no") || _param_str_ieq(s, "off"))
    return false;

  fprintf(stderr,
          "WARNING: Invalid bool for '%s' ('%s'), using default %d\n",
          key, s, default_value ? 1 : 0);
  return default_value;
}

#endif
