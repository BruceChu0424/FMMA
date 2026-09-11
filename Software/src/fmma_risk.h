/*
 * FMMA - host-side risk.
 *
 * The position limit lives in the fabric, on the decision path, where a
 * broken host cannot bypass it (docs/09).  This module is the second
 * layer: the things the fabric cannot know because they need a price
 * history and a notion of money.
 *
 *   - realised and unrealised profit and loss
 *   - a loss limit that stops trading
 *   - a stale-feed watchdog
 *
 * None of it replaces the fabric's limit; it sits in front of it.  If
 * this module says no, no order is sent; if it says yes, the fabric
 * still gets to refuse.
 */
#ifndef FMMA_RISK_H
#define FMMA_RISK_H

#include <stdint.h>

enum fmma_risk_verdict {
    FMMA_RISK_OK = 0,
    FMMA_RISK_LOSS_LIMIT,      /* the loss limit has been hit         */
    FMMA_RISK_STALE_FEED,      /* no quote for too long               */
    FMMA_RISK_HALTED           /* an operator or a fault halted us    */
};

struct fmma_risk {
    int32_t  position;         /* lots, signed                        */
    int64_t  avg_price;        /* average entry, price units, or 0    */
    int64_t  realised;         /* realised P&L, price units x lots    */
    int64_t  unrealised;       /* marked to the last mid              */
    int64_t  max_loss;         /* 0 disables the limit                */
    uint32_t stale_feed_ms;
    int      halted;
    const char *halt_reason;
};

void fmma_risk_init(struct fmma_risk *r, int64_t max_loss,
                    uint32_t stale_feed_ms, int32_t start_position);

/* Apply a fill. `side` is FMMA_FILL_BOUGHT or FMMA_FILL_SOLD. */
void fmma_risk_on_fill(struct fmma_risk *r, uint32_t side, uint32_t qty,
                       int64_t price);

/* Mark to market against the current mid. */
void fmma_risk_mark(struct fmma_risk *r, int64_t mid);

/* Total P&L in price units. */
int64_t fmma_risk_pnl(const struct fmma_risk *r);

/* Stop everything, with a reason for the log. */
void fmma_risk_halt(struct fmma_risk *r, const char *reason);

/*
 * May an order be sent right now?  `feed_age_us` comes from the stats
 * module.  Logs the reason the first time each verdict changes.
 */
enum fmma_risk_verdict fmma_risk_check(struct fmma_risk *r,
                                       uint64_t feed_age_us);

const char *fmma_risk_verdict_text(enum fmma_risk_verdict v);

/* One line for the periodic summary. */
void fmma_risk_report(const struct fmma_risk *r);

#endif /* FMMA_RISK_H */
