/*
 * FMMA - just enough JSON to read an exchange ticker.
 *
 * The feed sends flat objects of string and number fields.  A real JSON
 * parser would be a dependency, a heap allocation per message and a
 * parsing pass over fields nobody reads; this walks the text once per
 * field that is actually wanted.
 *
 * It is deliberately not a general JSON parser: it does not handle nested
 * objects, escapes inside the values it returns, or duplicate keys.  If
 * the feed ever needs those, replace this rather than extending it.
 */
#ifndef FMMA_JSON_H
#define FMMA_JSON_H

#include <stddef.h>

/*
 * Find "name":"<value>" and return a pointer to the first character of
 * the value, inside `json`.  NULL if the field is not present.
 * The value is NOT null-terminated - it ends at the closing quote.
 */
const char *fmma_json_string(const char *json, const char *name);

/*
 * Copy "name":"<value>" into `out` as a null-terminated string.
 * Returns 0 on success, -1 if the field is missing or does not fit.
 */
int fmma_json_copy_string(const char *json, const char *name,
                          char *out, size_t outlen);

/*
 * True if the document has "type":"<want>" exactly.
 *
 * Worth its own function because the obvious shortcut is wrong: looking
 * for the substring "ticker" also matches the channel list in the
 * subscription acknowledgement, and looking for "match" also matches
 * Coinbase's "last_match" message type.
 */
int fmma_json_type_is(const char *json, const char *want);

#endif /* FMMA_JSON_H */
