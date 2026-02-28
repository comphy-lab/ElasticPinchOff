/**
# params.h

Hyphal-flow style runtime parameter accessors with defaults.

This header provides a lightweight API for simulation cases:

1. Initialize parameter storage from `argv`:
   `params_init_from_argv(argc, argv);`
2. Read typed values with defaults:
   - `param_int("MAXlevel", 12)`
   - `param_double("tmax", 200.)`
   - `param_bool("use_feature", false)`

Invalid values do not abort immediately; instead a warning is printed and
the provided default is returned.
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

/**
### params_init_from_argv()

Initializes the parameter map from `argv[1]` when provided.
If no file argument is given, falls back to `case.params`.
*/
static inline void params_init_from_argv (int argc, const char * argv[])
{
  parse_params_init_from_argv(argc, argv);
}

/**
### param_string()

Returns string value for `key`, or `default_value` when key is missing.
*/
static inline const char * param_string (const char * key,
                                         const char * default_value)
{
  return parse_param_string(key, default_value);
}

/**
### param_double()

Returns a floating-point parameter with a default fallback.
*/
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

/**
### param_int()

Returns an integer parameter with bounds and format validation.
*/
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

/**
### param_bool()

Parses boolean-like values:
- true: `1`, `true`, `yes`, `on`
- false: `0`, `false`, `no`, `off`

All matches are case-insensitive.
*/
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
