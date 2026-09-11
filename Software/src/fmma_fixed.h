/*
 * FMMA - fixed-point decimal conversion.
 *
 * Prices cross into the FPGA as scaled integers, and they have to be
 * exact.  The obvious implementation - strtof() then multiply - loses the
 * bottom bits: a float carries 24 bits of mantissa and a BTC price scaled
 * by 10000 needs 30, so the decimal places the protocol advertises are not
 * the decimal places it delivers.  These routines never touch a float.
 */
#ifndef FMMA_FIXED_H
#define FMMA_FIXED_H

#include <stddef.h>
#include <stdint.h>

/* Returned by fmma_parse_scaled when the text is not a number. */
#define FMMA_PARSE_ERROR  INT64_MIN

/*
 * Parse a decimal string ("97431.02", "-3", "0.0013") into an integer
 * scaled by `scale`, truncating toward zero beyond the scale's precision.
 *
 *     fmma_parse_scaled("97431.02", 100)   -> 9743102
 *     fmma_parse_scaled("0.0013", 10000)   -> 13
 *     fmma_parse_scaled("nope", 100)       -> FMMA_PARSE_ERROR
 *
 * Stops at the first character that cannot be part of the number, so it
 * is safe to hand it a pointer into the middle of a JSON document.
 * Saturates rather than wrapping if the integer part is absurd.
 */
int64_t fmma_parse_scaled(const char *s, uint32_t scale);

/*
 * Format a scaled integer back into a decimal string.  `buf` must have
 * room for at least 24 characters.  Returns buf.
 */
const char *fmma_format_scaled(char *buf, size_t buflen,
                               int64_t value, uint32_t scale);

/*
 * Clamp a parsed price into the range the FPGA's signed comparisons can
 * represent.  The strategy adds bid and ask together, so each side must
 * stay below 2^30 for the sum to remain a positive signed 32-bit value.
 *
 * Returns 0 and sets *clamped when the value was out of range, so the
 * caller can log it rather than trading on a silently mangled number.
 */
#define FMMA_PRICE_MAX  0x3FFFFFFFL

uint32_t fmma_clamp_price(int64_t value, int *clamped);

#endif /* FMMA_FIXED_H */
