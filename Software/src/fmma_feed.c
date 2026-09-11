#include "fmma_feed.h"
#include "fmma_fixed.h"
#include "fmma_json.h"
#include "fmma_log.h"
#include "fmma_stats.h"
#include "fmma_time.h"
#include "fmma_tls.h"

#include "../fmma_protocol.h"
#include "../third_party/mongoose.h"

#include <stdlib.h>
#include <string.h>

#define TAG "feed"

#define COINBASE_URL   "wss://ws-feed.exchange.coinbase.com"
#define COINBASE_HOST  "ws-feed.exchange.coinbase.com"

#define BACKOFF_MIN_MS   500
#define BACKOFF_MAX_MS 30000
#define SIZE_SCALE       10000    /* sizes are fractional; keep 4 places */

struct fmma_feed {
    struct mg_mgr         *mgr;
    struct mg_connection  *conn;
    const char            *product;
    struct fmma_stats     *stats;
    fmma_quote_cb          on_quote;
    void                  *user;

    uint64_t reconnect_at_us;
    uint32_t backoff_ms;
    int      connected;
};

static void schedule_reconnect(struct fmma_feed *f)
{
    f->conn = NULL;
    f->connected = 0;
    f->reconnect_at_us = fmma_now_us() + (uint64_t)f->backoff_ms * 1000ull;
    FMMA_WARN(TAG, "reconnecting in %u ms", f->backoff_ms);
    f->backoff_ms *= 2;
    if (f->backoff_ms > BACKOFF_MAX_MS) f->backoff_ms = BACKOFF_MAX_MS;
}

static void handle_ticker(struct fmma_feed *f, const char *json)
{
    const char *bid_s = fmma_json_string(json, "best_bid");
    const char *ask_s = fmma_json_string(json, "best_ask");
    if (bid_s == NULL || ask_s == NULL) return;

    int64_t bid = fmma_parse_scaled(bid_s, FMMA_PRICE_SCALE);
    int64_t ask = fmma_parse_scaled(ask_s, FMMA_PRICE_SCALE);
    if (bid == FMMA_PARSE_ERROR || ask == FMMA_PARSE_ERROR) return;

    int clamped_b = 0, clamped_a = 0;
    struct fmma_quote q;
    q.bid = fmma_clamp_price(bid, &clamped_b);
    q.ask = fmma_clamp_price(ask, &clamped_a);
    if (clamped_b || clamped_a) {
        f->stats->clamped_prices++;
        FMMA_WARN(TAG, "quote outside the fixed-point range was clamped "
                       "(bid %lld ask %lld)", (long long)bid, (long long)ask);
    }
    if (q.bid == 0 || q.ask == 0) return;

    const char *bsz = fmma_json_string(json, "best_bid_size");
    const char *asz = fmma_json_string(json, "best_ask_size");
    int64_t b = bsz ? fmma_parse_scaled(bsz, SIZE_SCALE) : 0;
    int64_t a = asz ? fmma_parse_scaled(asz, SIZE_SCALE) : 0;
    q.bid_size = (b > 0 && b < 0x7FFFFFFF) ? (uint32_t)b : 0;
    q.ask_size = (a > 0 && a < 0x7FFFFFFF) ? (uint32_t)a : 0;

    if (fmma_log_get_level() >= FMMA_LOG_DEBUG) {
        char bb[24], aa[24];
        FMMA_DEBUG(TAG, "bid %s  ask %s",
                   fmma_format_scaled(bb, sizeof(bb), bid, FMMA_PRICE_SCALE),
                   fmma_format_scaled(aa, sizeof(aa), ask, FMMA_PRICE_SCALE));
    }

    if (f->on_quote) f->on_quote(f->user, &q);
}

static void feed_cb(struct mg_connection *c, int ev, void *ev_data)
{
    struct fmma_feed *f = (struct fmma_feed *)c->fn_data;
    if (f == NULL) return;

    if (ev == MG_EV_CONNECT) {
        fmma_tls_start(c, COINBASE_HOST);
    }
    else if (ev == MG_EV_WS_OPEN) {
        char sub[256];
        int n = snprintf(sub, sizeof(sub),
                         "{\"type\":\"subscribe\",\"product_ids\":[\"%s\"],"
                         "\"channels\":[\"ticker\"]}", f->product);
        mg_ws_send(c, sub, (size_t)n, WEBSOCKET_OP_TEXT);
        f->connected = 1;
        f->backoff_ms = BACKOFF_MIN_MS;     /* a good connection resets it */
        FMMA_INFO(TAG, "connected, subscribed to %s ticker", f->product);
    }
    else if (ev == MG_EV_WS_MSG) {
        struct mg_ws_message *wm = (struct mg_ws_message *)ev_data;

        /* Most messages fit comfortably; fall back to the heap rather
         * than truncating, because a truncated JSON object would parse
         * as a missing field and be silently dropped. */
        char stack[2048];
        char *buf = stack;
        if (wm->data.len + 1 > sizeof(stack)) {
            buf = (char *)malloc(wm->data.len + 1);
            if (buf == NULL) return;
        }
        memcpy(buf, wm->data.buf, wm->data.len);
        buf[wm->data.len] = '\0';

        if (fmma_json_type_is(buf, "ticker"))
            handle_ticker(f, buf);
        else if (fmma_json_type_is(buf, "error"))
            FMMA_ERROR(TAG, "exchange error: %s", buf);
        else if (fmma_json_type_is(buf, "subscriptions"))
            FMMA_DEBUG(TAG, "subscription confirmed");

        if (buf != stack) free(buf);
    }
    else if (ev == MG_EV_ERROR) {
        FMMA_ERROR(TAG, "error: %s", (char *)ev_data);
        f->stats->errors++;
    }
    else if (ev == MG_EV_CLOSE) {
        if (f->connected) f->stats->feed_drops++;
        FMMA_WARN(TAG, "disconnected");
        schedule_reconnect(f);
    }
}

/* ------------------------------------------------------------------ */

struct fmma_feed *fmma_feed_create(struct mg_mgr *mgr, const char *product,
                                   struct fmma_stats *stats,
                                   fmma_quote_cb on_quote, void *user)
{
    struct fmma_feed *f = calloc(1, sizeof(*f));
    if (f == NULL) return NULL;
    f->mgr = mgr;
    f->product = product;
    f->stats = stats;
    f->on_quote = on_quote;
    f->user = user;
    f->backoff_ms = BACKOFF_MIN_MS;
    return f;
}

void fmma_feed_destroy(struct fmma_feed *f) { free(f); }

void fmma_feed_start(struct fmma_feed *f)
{
    f->conn = mg_ws_connect(f->mgr, COINBASE_URL, feed_cb, f, NULL);
    if (f->conn == NULL) {
        FMMA_ERROR(TAG, "could not start a connection");
        schedule_reconnect(f);
    }
}

void fmma_feed_poll(struct fmma_feed *f)
{
    if (f->conn == NULL && f->reconnect_at_us &&
        fmma_now_us() >= f->reconnect_at_us) {
        f->reconnect_at_us = 0;
        fmma_feed_start(f);
    }
}

int fmma_feed_connected(const struct fmma_feed *f)
{
    return f && f->connected;
}
