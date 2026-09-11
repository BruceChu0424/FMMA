/*
 * FMMA - the strategy, in software.
 *
 * This is a transcription of what trading.asm does in the fabric.  It
 * exists for two reasons and neither of them is to run the system:
 *
 *   --no-fpga   lets the feed, the parser and the execution path be
 *               developed and tested on a laptop with no board
 *   --bench     times the same arithmetic on the ARM core so the
 *               fabric's figure has something to be compared against
 *
 * Keeping it here rather than inline in the event loop makes the
 * comparison honest: it is a function with the same inputs and the same
 * outputs as the hardware, and it can be unit tested against the same
 * scenarios (see test_strategy.py, which drives the assembly version
 * through the instruction set simulator).
 */
#ifndef FMMA_STRATEGY_H
#define FMMA_STRATEGY_H

#include <stdint.h>

struct fmma_strategy {
    int64_t  anchor;        /* bid+ask at the last decision point, 0 = none */
    uint32_t threshold;     /* price units                                  */
    uint32_t max_position;  /* lots                                         */
    int32_t  position;      /* lots, signed                                 */
    int      enabled;
    uint64_t rejects;       /* decisions suppressed by the limit            */
};

void fmma_strategy_init(struct fmma_strategy *s, uint32_t threshold,
                        uint32_t max_position, int32_t start_position);

/*
 * Feed one quote.  Returns FMMA_SIGNAL_NONE, _BUY or _SELL.
 *
 * Mirrors the assembly exactly, including working with twice the mid so
 * there is no divide, and re-anchoring on every quote.
 */
uint32_t fmma_strategy_on_quote(struct fmma_strategy *s,
                                uint32_t bid, uint32_t ask);

/* Keep the software position in step when a fill is reported. */
void fmma_strategy_on_fill(struct fmma_strategy *s, uint32_t side,
                           uint32_t qty);

#endif /* FMMA_STRATEGY_H */
