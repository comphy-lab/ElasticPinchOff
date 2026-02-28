/**
# parse_params.h

Low-level key=value parameter map used by params.h.
*/

#ifndef PARSE_PARAMS_H
#define PARSE_PARAMS_H

#include <ctype.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#ifndef PARSE_PARAMS_MAX_ENTRIES
#define PARSE_PARAMS_MAX_ENTRIES 256
#endif

#ifndef PARSE_PARAMS_KEY_LEN
#define PARSE_PARAMS_KEY_LEN 128
#endif

#ifndef PARSE_PARAMS_VALUE_LEN
#define PARSE_PARAMS_VALUE_LEN 256
#endif

typedef struct {
  char key[PARSE_PARAMS_KEY_LEN];
  char value[PARSE_PARAMS_VALUE_LEN];
} ParseParamEntry;

static ParseParamEntry _parse_params_entries[PARSE_PARAMS_MAX_ENTRIES];
static int _parse_params_count = 0;
static bool _parse_params_loaded = false;
static bool _parse_params_warned_missing = false;
static char _parse_params_file[PARSE_PARAMS_VALUE_LEN] = "case.params";

static inline char * parse_params_trim (char * s)
{
  if (!s)
    return s;

  while (*s && isspace((unsigned char) *s))
    s++;

  size_t n = strlen(s);
  while (n > 0 && isspace((unsigned char) s[n - 1]))
    s[--n] = '\0';

  return s;
}

static inline int parse_params_find_key (const char * key)
{
  for (int i = 0; i < _parse_params_count; i++)
    if (!strcmp(_parse_params_entries[i].key, key))
      return i;
  return -1;
}

static inline void parse_params_set_value (const char * key,
                                           const char * value)
{
  int idx = parse_params_find_key(key);

  if (idx < 0) {
    if (_parse_params_count >= PARSE_PARAMS_MAX_ENTRIES) {
      fprintf(stderr,
              "WARNING: parse_params entry limit reached (%d),"
              " skipping '%s'\n",
              PARSE_PARAMS_MAX_ENTRIES, key);
      return;
    }

    idx = _parse_params_count++;
    strncpy(_parse_params_entries[idx].key, key, PARSE_PARAMS_KEY_LEN - 1);
    _parse_params_entries[idx].key[PARSE_PARAMS_KEY_LEN - 1] = '\0';
  }

  strncpy(_parse_params_entries[idx].value, value, PARSE_PARAMS_VALUE_LEN - 1);
  _parse_params_entries[idx].value[PARSE_PARAMS_VALUE_LEN - 1] = '\0';
}

static inline int parse_params_load (const char * filename)
{
  _parse_params_count = 0;
  _parse_params_loaded = true;

  FILE * fp = fopen(filename, "r");
  if (!fp) {
    if (!_parse_params_warned_missing) {
      fprintf(stderr,
              "WARNING: Parameter file '%s' not found. Using defaults.\n",
              filename);
      _parse_params_warned_missing = true;
    }
    return -1;
  }

  char line[PARSE_PARAMS_KEY_LEN + PARSE_PARAMS_VALUE_LEN + 64];
  while (fgets(line, sizeof(line), fp)) {
    char * comment = strchr(line, '#');
    if (comment)
      *comment = '\0';

    char * eq = strchr(line, '=');
    if (!eq)
      continue;

    *eq = '\0';
    char * key = parse_params_trim(line);
    char * value = parse_params_trim(eq + 1);
    if (!key || !value || !*key || !*value)
      continue;

    parse_params_set_value(key, value);
  }

  fclose(fp);
  return 0;
}

static inline void parse_params_init_from_argv (int argc,
                                                const char * argv[])
{
  if (argc > 1 && argv[1] && argv[1][0]) {
    strncpy(_parse_params_file, argv[1], PARSE_PARAMS_VALUE_LEN - 1);
    _parse_params_file[PARSE_PARAMS_VALUE_LEN - 1] = '\0';
  }
  else {
    strncpy(_parse_params_file, "case.params", PARSE_PARAMS_VALUE_LEN - 1);
    _parse_params_file[PARSE_PARAMS_VALUE_LEN - 1] = '\0';
  }

  (void) parse_params_load(_parse_params_file);
}

static inline void parse_params_ensure_loaded (void)
{
  if (!_parse_params_loaded)
    (void) parse_params_load(_parse_params_file);
}

static inline const char * parse_param_string (const char * key,
                                               const char * default_value)
{
  parse_params_ensure_loaded();
  int idx = parse_params_find_key(key);
  return idx >= 0 ? _parse_params_entries[idx].value : default_value;
}

#endif
