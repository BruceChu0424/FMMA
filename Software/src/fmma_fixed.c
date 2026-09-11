#include "fmma_fixed.h"

#include <stdio.h>
#include <stddef.h>

/* Anything past this in the integer part is not a real price; saturate
 * instead of wrapping so a malformed feed cannot produce a small number. */
#define WHOLE_SATURATE  100000000LL

int64_t fmma_parse_scaled(const char *s, uint32_t scale)
{
    if (s == NULL || scale == 0) return FMMA_PARSE_ERROR;

    const char *p = s;
    int neg = 0;

    if (*p == '-') { neg = 1; p++; }
    else if (*p == '+') { p++; }

    if (*p < '0' || *p > '9') return FMMA_PARSE_ERROR;

    int64_t whole = 0;
    while (*p >= '0' && *p <= '9') {
        if (whole < WHOLE_SATURATE)
            whole = whole * 10 + (*p - '0');
        p++;
    }

    int64_t frac = 0;
    uint32_t div = 1;
    if (*p == '.') {
        p++;
        while (*p >= '0' && *p <= '9') {
            if (div < scale) {
                frac = frac * 10 + (*p - '0');
                div *= 10;
            }
            /* digits beyond the scale are truncated, not rounded */
            p++;
        }
    }
    while (div < scale) { frac *= 10; div *= 10; }

    int64_t v = whole * (int64_t)scale + frac;
    return neg ? -v : v;
}

const char *fmma_format_scaled(char *buf, size_t buflen,
                               int64_t value, uint32_t scale)
{
    if (buf == NULL || buflen == 0) return buf;
    if (scale == 0) scale = 1;

    int neg = value < 0;
    uint64_t mag = (uint64_t)(neg ? -value : value);
    uint64_t whole = mag / scale;
    uint64_t frac = mag % scale;

    /* How many digits the scale implies: 100 -> 2, 10000 -> 4.
     * Bounded so the width in the format below is provably small - an
     * unbounded '%0*llu' width is a buffer overflow waiting for a
     * caller who passes a nonsense scale. */
    int digits = 0;
    for (uint32_t d = scale; d > 1 && digits < 9; d /= 10) digits++;

    if (digits > 0)
        snprintf(buf, buflen, "%s%llu.%0*llu", neg ? "-" : "",
                 (unsigned long long)whole, digits, (unsigned long long)frac);
    else
        snprintf(buf, buflen, "%s%llu", neg ? "-" : "",
                 (unsigned long long)whole);
    return buf;
}

uint32_t fmma_clamp_price(int64_t value, int *clamped)
{
    if (clamped) *clamped = 0;
    if (value < 0) {
        if (clamped) *clamped = 1;
        return 0;
    }
    if (value > FMMA_PRICE_MAX) {
        if (clamped) *clamped = 1;
        return (uint32_t)FMMA_PRICE_MAX;
    }
    return (uint32_t)value;
}
