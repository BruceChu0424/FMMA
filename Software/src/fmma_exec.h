/*
 * FMMA - order execution against Alpaca.
 *
 * Sends a market order, then follows it to a terminal state instead of
 * assuming it filled.  That second part matters: the fabric's position
 * limit is only as good as the position, and the position is only right
 * if a fill report means a fill actually happened.
 *
 * The previous version reported a fill as soon as the POST returned
 * 2xx, which conflates "the broker accepted the order" with "the order
 * executed".  For a paper market order those are nearly the same thing,
 * but "nearly" is how a risk limit stops working.
 *
 * Credentials are read from the environment once at init and are never
 * logged.
 */
#ifndef FMMA_EXEC_H
#define FMMA_EXEC_H

#include <stdint.h>

struct mg_mgr;
struct fmma_config;
struct fmma_stats;

/* Called when an order reaches a terminal state. `qty` is in lots. */
typedef void (*fmma_fill_cb)(void *user, uint32_t side, uint32_t qty,
                             int64_t price);

struct fmma_exec;

struct fmma_exec *fmma_exec_create(struct mg_mgr *mgr,
                                   const struct fmma_config *cfg,
                                   struct fmma_stats *stats,
                                   fmma_fill_cb on_fill, void *user);
void fmma_exec_destroy(struct fmma_exec *e);

/* True when both API credentials were found in the environment. */
int fmma_exec_have_credentials(const struct fmma_exec *e);

/*
 * Send one order.  `side` is FMMA_SIGNAL_BUY or FMMA_SIGNAL_SELL,
 * `mark` is the current mid, used only to price the fill for P&L.
 * Returns 0 if the order went out, -1 if it was suppressed (cooldown,
 * dry run, missing credentials).
 */
int fmma_exec_send(struct fmma_exec *e, uint32_t side, int64_t mark);

/* Drive order-status polling; call from the event loop. */
void fmma_exec_poll(struct fmma_exec *e);

/* How many orders are still working. */
unsigned fmma_exec_pending(const struct fmma_exec *e);

#endif /* FMMA_EXEC_H */
