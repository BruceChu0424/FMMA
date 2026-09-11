#include "fmma_json.h"

#include <stdio.h>
#include <string.h>

#define PATTERN_MAX 64

const char *fmma_json_string(const char *json, const char *name)
{
    if (json == NULL || name == NULL) return NULL;

    char pattern[PATTERN_MAX];
    int n = snprintf(pattern, sizeof(pattern), "\"%s\":\"", name);
    if (n <= 0 || (size_t)n >= sizeof(pattern)) return NULL;

    const char *p = strstr(json, pattern);
    return p ? p + n : NULL;
}

int fmma_json_copy_string(const char *json, const char *name,
                          char *out, size_t outlen)
{
    if (out == NULL || outlen == 0) return -1;
    out[0] = '\0';

    const char *v = fmma_json_string(json, name);
    if (v == NULL) return -1;

    const char *end = strchr(v, '"');
    if (end == NULL) return -1;

    size_t len = (size_t)(end - v);
    if (len + 1 > outlen) return -1;

    memcpy(out, v, len);
    out[len] = '\0';
    return 0;
}

int fmma_json_type_is(const char *json, const char *want)
{
    const char *v = fmma_json_string(json, "type");
    if (v == NULL || want == NULL) return 0;

    size_t n = strlen(want);
    return strncmp(v, want, n) == 0 && v[n] == '"';
}
