#include "fmma_risk.h"
#include "fmma_log.h"

#include "../fmma_protocol.h"

#include <stdlib.h>
#include <string.h>

#define TAG "risk"

void fmma_risk_init(struct fmma_risk *r, int64_t max_loss,
                    uint32_t stale_feed_ms, int32_t start_position)
{
    memset(r, 0, sizeof(*r));
    r->max_loss = max_loss;
    r->stale_feed_ms = stale_feed_ms;
    r->position = start_position;
}

/*
 * Average-cost accounting.  Adding to a position moves the average;
 * reducing it realises the difference against the average and leaves
 * the average alone.  Crossing through zero does both.
 */
void fmma_risk_on_fill(struct fmma_risk *r, uint32_t side, uint32_t qty,
                       int64_t price)
{
    if (qty == 0) return;
    int32_t signed_qty = (side == FMMA_FILL_BOUGHT) ? (int32_t)qty
                                                    : -(int32_t)qty;
    int32_t old = r->position;
    int32_t newpos = old + signed_qty;

    int adding = (old == 0) || ((old > 0) == (signed_qty > 0));

    if (adding) {
        int64_t total = r->avg_price * labs((long)old) + price * (long)qty;
        long units = labs((long)old) + (long)qty;
        r->avg_price = units ? total / units : 0;
    } else {
        /* Closing, possibly through zero. */
        int32_t closed = (labs((long)signed_qty) < labs((long)old))
                       ? (int32_t)labs((long)signed_qty)
                       : (int32_t)labs((long)old);
        int64_t per_lot = (old > 0) ? (price - r->avg_price)
                                    : (r->avg_price - price);
        r->realised += per_lot * closed;

        if ((old > 0) != (newpos > 0) && newpos != 0) {
            /* Flipped sides: the remainder opens at this price. */
            r->avg_price = price;
        } else if (newpos == 0) {
            r->avg_price = 0;
        }
    }

    r->position = newpos;
    FMMA_INFO(TAG, "fill %s %u @ %lld -> position %d, avg %lld, "
                   "realised %lld",
              side == FMMA_FILL_BOUGHT ? "buy" : "sell", qty,
              (long long)price, r->position, (long long)r->avg_price,
              (long long)r->realised);
}

void fmma_risk_mark(struct fmma_risk *r, int64_t mid)
{
    if (r->position == 0 || r->avg_price == 0) {
        r->unrealised = 0;
        return;
    }
    r->unrealised = (mid - r->avg_price) * r->position;
}

int64_t fmma_risk_pnl(const struct fmma_risk *r)
{
    return r->realised + r->unrealised;
}

void fmma_risk_halt(struct fmma_risk *r, const char *reason)
{
    if (!r->halted) {
        r->halted = 1;
        r->halt_reason = reason;
        FMMA_ERROR(TAG, "HALTED: %s", reason);
    }
}

enum fmma_risk_verdict fmma_risk_check(struct fmma_risk *r,
                                       uint64_t feed_age_us)
{
    if (r->halted) return FMMA_RISK_HALTED;

    if (r->max_loss > 0 && fmma_risk_pnl(r) <= -r->max_loss) {
        fmma_risk_halt(r, "loss limit reached");
        return FMMA_RISK_LOSS_LIMIT;
    }

    if (r->stale_feed_ms > 0 &&
        feed_age_us > (uint64_t)r->stale_feed_ms * 1000ull) {
        return FMMA_RISK_STALE_FEED;
    }

    return FMMA_RISK_OK;
}

const char *fmma_risk_verdict_text(enum fmma_risk_verdict v)
{
    switch (v) {
    case FMMA_RISK_OK:         return "ok";
    case FMMA_RISK_LOSS_LIMIT: return "loss limit reached";
    case FMMA_RISK_STALE_FEED: return "market data is stale";
    default:                   return "halted";
    }
}

void fmma_risk_report(const struct fmma_risk *r)
{
    fmma_print("  position %d lots @ %lld   P&L realised %lld  "
               "unrealised %lld  total %lld%s\n",
               r->position, (long long)r->avg_price,
               (long long)r->realised, (long long)r->unrealised,
               (long long)fmma_risk_pnl(r),
               r->halted ? "   [HALTED]" : "");
}
