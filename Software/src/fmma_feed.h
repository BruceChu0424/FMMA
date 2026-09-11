/*
 * FMMA - the market data feed.
 *
 * A Coinbase Exchange WebSocket client subscribed to the `ticker`
 * channel, which carries best_bid and best_ask - real top-of-book
 * quotes.
 *
 * The obvious alternative, the `matches` channel, is what the first
 * version of this project used, and it is wrong for this purpose:
 * matches are executed trades, and the `side` field is the *maker*
 * side, so the two numbers it yields are the last taker-buy print and
 * the last taker-sell print.  They are not a bid and an ask, they are
 * not a snapshot of anything, and comparing them - which is what the
 * old strategy did - does not mean what it looks like it means.
 *
 * The client reconnects on its own with exponential backoff.  A feed
 * that dies quietly and never comes back is the failure this protects
 * against: the heartbeat keeps ticking, so everything looks healthy
 * while no data is arriving at all.
 */
#ifndef FMMA_FEED_H
#define FMMA_FEED_H

#include <stdint.h>

struct mg_mgr;
struct fmma_stats;

/* One top-of-book snapshot, already in fixed point. */
struct fmma_quote {
    uint32_t bid;        /* price units (cents)          */
    uint32_t ask;
    uint32_t bid_size;   /* x 10000                      */
    uint32_t ask_size;
};

typedef void (*fmma_quote_cb)(void *user, const struct fmma_quote *q);

struct fmma_feed;

struct fmma_feed *fmma_feed_create(struct mg_mgr *mgr, const char *product,
                                   struct fmma_stats *stats,
                                   fmma_quote_cb on_quote, void *user);
void fmma_feed_destroy(struct fmma_feed *f);

/* Open the connection, or schedule one. */
void fmma_feed_start(struct fmma_feed *f);

/* Drive reconnection; call from the event loop. */
void fmma_feed_poll(struct fmma_feed *f);

int fmma_feed_connected(const struct fmma_feed *f);

#endif /* FMMA_FEED_H */
