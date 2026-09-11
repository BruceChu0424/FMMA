#include "fmma_strategy.h"

#include "../fmma_protocol.h"

#include <string.h>

void fmma_strategy_init(struct fmma_strategy *s, uint32_t threshold,
                        uint32_t max_position, int32_t start_position)
{
    memset(s, 0, sizeof(*s));
    s->threshold = threshold;
    s->max_position = max_position;
    s->position = start_position;
    s->enabled = 1;
}

uint32_t fmma_strategy_on_quote(struct fmma_strategy *s,
                                uint32_t bid, uint32_t ask)
{
    /* Both sides of the book, or nothing to do. */
    if (bid == 0 || ask == 0) return FMMA_SIGNAL_NONE;

    /* Twice the mid: the factor of two cancels on both sides of the
     * band test, so the divide is unnecessary. */
    int64_t sum = (int64_t)bid + (int64_t)ask;
    int64_t band = 2 * (int64_t)s->threshold;

    if (s->anchor == 0) {           /* first quote: anchor only */
        s->anchor = sum;
        return FMMA_SIGNAL_NONE;
    }

    uint32_t want = FMMA_SIGNAL_NONE;
    if (sum < s->anchor - band)      want = FMMA_SIGNAL_BUY;
    else if (sum > s->anchor + band) want = FMMA_SIGNAL_SELL;

    /* Re-anchor on every quote, decision or not: the trigger is a move
     * between consecutive quotes, not a drift from some start price. */
    s->anchor = sum;

    if (want == FMMA_SIGNAL_NONE) return FMMA_SIGNAL_NONE;

    if (!s->enabled) { s->rejects++; return FMMA_SIGNAL_NONE; }

    /* Same limit the fabric enforces: the reducing side stays allowed. */
    if (want == FMMA_SIGNAL_BUY && s->position >= (int32_t)s->max_position) {
        s->rejects++;
        return FMMA_SIGNAL_NONE;
    }
    if (want == FMMA_SIGNAL_SELL && s->position <= -(int32_t)s->max_position) {
        s->rejects++;
        return FMMA_SIGNAL_NONE;
    }
    return want;
}

void fmma_strategy_on_fill(struct fmma_strategy *s, uint32_t side,
                           uint32_t qty)
{
    if (side == FMMA_FILL_BOUGHT) s->position += (int32_t)qty;
    else                          s->position -= (int32_t)qty;
}
