#include "fmma_exec.h"
#include "fmma_config.h"
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

#define TAG "exec"

#define ALPACA_HOST      "paper-api.alpaca.markets"
#define ALPACA_ORDERS    "https://paper-api.alpaca.markets/v2/orders"
#define MAX_PENDING      8
#define ORDER_ID_LEN     48

/* An order we have sent and are still following. */
struct pending {
    int      active;
    char     id[ORDER_ID_LEN];
    uint32_t side;
    int64_t  mark;              /* mid when we sent it, for P&L if the
                                   broker does not report a fill price */
    uint64_t sent_us;
    uint64_t last_poll_us;
    int      query_in_flight;
};

struct fmma_exec {
    struct mg_mgr             *mgr;
    const struct fmma_config  *cfg;
    struct fmma_stats         *stats;
    fmma_fill_cb               on_fill;
    void                      *user;

    const char *key;
    const char *secret;

    struct pending pending[MAX_PENDING];
    uint64_t last_order_ms;
};

/* Context handed to a mongoose connection. */
struct req_ctx {
    struct fmma_exec *e;
    int               slot;      /* index into pending, -1 for a new order */
};

/* ------------------------------------------------------------------ */

static struct pending *slot_alloc(struct fmma_exec *e, int *index)
{
    for (int i = 0; i < MAX_PENDING; i++) {
        if (!e->pending[i].active) {
            memset(&e->pending[i], 0, sizeof(e->pending[i]));
            e->pending[i].active = 1;
            *index = i;
            return &e->pending[i];
        }
    }
    return NULL;
}

static void auth_headers(struct fmma_exec *e, char *buf, size_t n)
{
    snprintf(buf, n,
             "APCA-API-KEY-ID: %s\r\nAPCA-API-SECRET-KEY: %s\r\n",
             e->key ? e->key : "", e->secret ? e->secret : "");
}

/*
 * Turn an order status into a decision.  Alpaca's terminal states are
 * filled, canceled, expired, rejected; everything else is still working.
 */
static int status_is_filled(const char *status)
{
    return strcmp(status, "filled") == 0;
}

static int status_is_terminal(const char *status)
{
    return status_is_filled(status) ||
           strcmp(status, "canceled") == 0 ||
           strcmp(status, "expired")  == 0 ||
           strcmp(status, "rejected") == 0 ||
           strcmp(status, "done_for_day") == 0;
}

static void settle(struct fmma_exec *e, int slot, const char *status,
                   int64_t price, uint32_t qty)
{
    struct pending *p = &e->pending[slot];
    if (!p->active) return;

    uint64_t rtt_ms = (fmma_now_us() - p->sent_us) / 1000;

    if (status_is_filled(status)) {
        e->stats->orders_filled++;
        FMMA_INFO(TAG, "filled %s %u @ %lld after %llu ms",
                  p->side == FMMA_SIGNAL_BUY ? "buy" : "sell",
                  qty, (long long)price, (unsigned long long)rtt_ms);
        if (e->on_fill)
            e->on_fill(e->user,
                       p->side == FMMA_SIGNAL_BUY ? FMMA_FILL_BOUGHT
                                                  : FMMA_FILL_SOLD,
                       qty, price);
    } else {
        e->stats->orders_rejected++;
        FMMA_WARN(TAG, "order %s (%s) after %llu ms - no fill reported",
                  p->id, status, (unsigned long long)rtt_ms);
    }
    p->active = 0;
}

/* ------------------------------------------------------------------ */
/* HTTP callbacks                                                      */
/* ------------------------------------------------------------------ */

static void order_cb(struct mg_connection *c, int ev, void *ev_data)
{
    struct req_ctx *ctx = (struct req_ctx *)c->fn_data;
    if (ctx == NULL) return;
    struct fmma_exec *e = ctx->e;

    if (ev == MG_EV_CONNECT) {
        fmma_tls_start(c, ALPACA_HOST);
    }
    else if (ev == MG_EV_HTTP_MSG) {
        struct mg_http_message *hm = (struct mg_http_message *)ev_data;
        int status = mg_http_status(hm);

        /* mongoose gives us a length-delimited body; the JSON helpers
         * want a C string. */
        char body[1024];
        size_t n = hm->body.len < sizeof(body) - 1 ? hm->body.len
                                                   : sizeof(body) - 1;
        memcpy(body, hm->body.buf, n);
        body[n] = '\0';

        if (status >= 200 && status < 300) {
            struct pending *p = &e->pending[ctx->slot];
            if (fmma_json_copy_string(body, "id", p->id, sizeof(p->id)) != 0)
                snprintf(p->id, sizeof(p->id), "(no id)");

            char st[32] = "accepted";
            fmma_json_copy_string(body, "status", st, sizeof(st));
            FMMA_INFO(TAG, "accepted (HTTP %d) id %s status %s",
                      status, p->id, st);

            /* Some brokers fill a paper market order synchronously; if
             * so there is nothing to poll for. */
            if (status_is_terminal(st)) {
                char fp[32] = "";
                int64_t price = p->mark;
                if (fmma_json_copy_string(body, "filled_avg_price",
                                          fp, sizeof(fp)) == 0 && fp[0]) {
                    int64_t v = fmma_parse_scaled(fp, FMMA_PRICE_SCALE);
                    if (v != FMMA_PARSE_ERROR) price = v;
                }
                settle(e, ctx->slot, st, price, 1);
            }
        } else {
            e->stats->orders_rejected++;
            FMMA_ERROR(TAG, "REJECTED (HTTP %d): %s", status, body);
            e->pending[ctx->slot].active = 0;
        }
        c->is_draining = 1;
    }
    else if (ev == MG_EV_ERROR) {
        e->stats->errors++;
        FMMA_ERROR(TAG, "connection error: %s", (char *)ev_data);
        e->pending[ctx->slot].active = 0;
    }
    else if (ev == MG_EV_CLOSE) {
        free(ctx);
        c->fn_data = NULL;
    }
}

static void query_cb(struct mg_connection *c, int ev, void *ev_data)
{
    struct req_ctx *ctx = (struct req_ctx *)c->fn_data;
    if (ctx == NULL) return;
    struct fmma_exec *e = ctx->e;
    struct pending *p = &e->pending[ctx->slot];

    if (ev == MG_EV_CONNECT) {
        fmma_tls_start(c, ALPACA_HOST);
    }
    else if (ev == MG_EV_HTTP_MSG) {
        struct mg_http_message *hm = (struct mg_http_message *)ev_data;
        char body[1024];
        size_t n = hm->body.len < sizeof(body) - 1 ? hm->body.len
                                                   : sizeof(body) - 1;
        memcpy(body, hm->body.buf, n);
        body[n] = '\0';

        char st[32] = "";
        if (fmma_json_copy_string(body, "status", st, sizeof(st)) == 0 &&
            status_is_terminal(st)) {
            char fp[32] = "", fq[32] = "";
            int64_t price = p->mark;
            uint32_t qty = 1;
            if (fmma_json_copy_string(body, "filled_avg_price",
                                      fp, sizeof(fp)) == 0 && fp[0]) {
                int64_t v = fmma_parse_scaled(fp, FMMA_PRICE_SCALE);
                if (v != FMMA_PARSE_ERROR) price = v;
            }
            if (fmma_json_copy_string(body, "filled_qty",
                                      fq, sizeof(fq)) == 0 && fq[0]) {
                /* A partial fill of a one-lot order is still one lot
                 * from the fabric's point of view; anything more needs
                 * fractional inventory, which the protocol does not
                 * carry.  Log it so it is visible if it ever happens. */
                if (fq[0] == '0' && fq[1] == '\0') qty = 0;
            }
            if (qty) settle(e, ctx->slot, st, price, qty);
            else {
                FMMA_WARN(TAG, "order %s %s with nothing filled", p->id, st);
                e->stats->orders_rejected++;
                p->active = 0;
            }
        }
        p->query_in_flight = 0;
        c->is_draining = 1;
    }
    else if (ev == MG_EV_ERROR) {
        p->query_in_flight = 0;
        e->stats->errors++;
    }
    else if (ev == MG_EV_CLOSE) {
        p->query_in_flight = 0;
        free(ctx);
        c->fn_data = NULL;
    }
}

/* ------------------------------------------------------------------ */

struct fmma_exec *fmma_exec_create(struct mg_mgr *mgr,
                                   const struct fmma_config *cfg,
                                   struct fmma_stats *stats,
                                   fmma_fill_cb on_fill, void *user)
{
    struct fmma_exec *e = calloc(1, sizeof(*e));
    if (e == NULL) return NULL;
    e->mgr = mgr;
    e->cfg = cfg;
    e->stats = stats;
    e->on_fill = on_fill;
    e->user = user;
    e->key    = getenv("APCA_API_KEY_ID");
    e->secret = getenv("APCA_API_SECRET_KEY");

    if (!fmma_exec_have_credentials(e))
        FMMA_WARN(TAG, "APCA_API_KEY_ID / APCA_API_SECRET_KEY are not set; "
                       "orders will be skipped (use sudo -E)");
    return e;
}

void fmma_exec_destroy(struct fmma_exec *e) { free(e); }

int fmma_exec_have_credentials(const struct fmma_exec *e)
{
    return e && e->key && e->secret && e->key[0] && e->secret[0];
}

unsigned fmma_exec_pending(const struct fmma_exec *e)
{
    unsigned n = 0;
    for (int i = 0; i < MAX_PENDING; i++) if (e->pending[i].active) n++;
    return n;
}

int fmma_exec_send(struct fmma_exec *e, uint32_t side, int64_t mark)
{
    const char *side_str = (side == FMMA_SIGNAL_BUY) ? "buy" : "sell";
    uint64_t now_ms = fmma_now_ms();

    if (now_ms - e->last_order_ms < e->cfg->cooldown_ms) {
        e->stats->cooldown_drops++;
        FMMA_INFO(TAG, "cooldown active, dropping %s", side_str);
        return -1;
    }
    if (e->cfg->dry_run) {
        FMMA_INFO(TAG, "dry run: would send %s %s %s",
                  side_str, e->cfg->qty, e->cfg->symbol);
        e->last_order_ms = now_ms;
        return -1;
    }
    if (!fmma_exec_have_credentials(e)) {
        e->stats->orders_rejected++;
        FMMA_WARN(TAG, "no credentials, skipping %s", side_str);
        return -1;
    }

    int slot = -1;
    struct pending *p = slot_alloc(e, &slot);
    if (p == NULL) {
        FMMA_WARN(TAG, "%d orders already working, dropping %s",
                  MAX_PENDING, side_str);
        return -1;
    }
    p->side = side;
    p->mark = mark;
    p->sent_us = fmma_now_us();
    p->last_poll_us = p->sent_us;

    struct req_ctx *ctx = calloc(1, sizeof(*ctx));
    if (ctx == NULL) { p->active = 0; return -1; }
    ctx->e = e;
    ctx->slot = slot;

    struct mg_connection *c = mg_http_connect(e->mgr, ALPACA_ORDERS,
                                              order_cb, ctx);
    if (c == NULL) {
        FMMA_ERROR(TAG, "could not open a connection to the broker");
        e->stats->errors++;
        free(ctx);
        p->active = 0;
        return -1;
    }

    char body[256], auth[512];
    int blen = snprintf(body, sizeof(body),
        "{\"symbol\":\"%s\",\"qty\":\"%s\",\"side\":\"%s\","
        "\"type\":\"market\",\"time_in_force\":\"gtc\"}",
        e->cfg->symbol, e->cfg->qty, side_str);
    auth_headers(e, auth, sizeof(auth));

    mg_printf(c,
        "POST /v2/orders HTTP/1.1\r\n"
        "Host: %s\r\n"
        "Content-Type: application/json\r\n"
        "Content-Length: %d\r\n"
        "%s"
        "Connection: close\r\n"
        "\r\n%s",
        ALPACA_HOST, blen, auth, body);

    e->stats->orders_sent++;
    e->last_order_ms = now_ms;
    FMMA_INFO(TAG, "sent %s %s %s", side_str, e->cfg->qty, e->cfg->symbol);
    return 0;
}

void fmma_exec_poll(struct fmma_exec *e)
{
    uint64_t now = fmma_now_us();
    uint64_t period = (uint64_t)e->cfg->order_poll_ms * 1000ull;

    for (int i = 0; i < MAX_PENDING; i++) {
        struct pending *p = &e->pending[i];
        if (!p->active || p->query_in_flight || p->id[0] == '\0') continue;
        if (now - p->last_poll_us < period) continue;
        p->last_poll_us = now;

        /* Give up eventually rather than polling a lost order forever. */
        if (now - p->sent_us > 60ull * 1000000ull) {
            FMMA_WARN(TAG, "order %s did not reach a terminal state in 60 s; "
                           "giving up on it", p->id);
            e->stats->orders_rejected++;
            p->active = 0;
            continue;
        }

        char url[256];
        snprintf(url, sizeof(url),
                 "https://%s/v2/orders/%s", ALPACA_HOST, p->id);

        struct req_ctx *ctx = calloc(1, sizeof(*ctx));
        if (ctx == NULL) continue;
        ctx->e = e;
        ctx->slot = i;

        struct mg_connection *c = mg_http_connect(e->mgr, url, query_cb, ctx);
        if (c == NULL) { free(ctx); continue; }

        char auth[512];
        auth_headers(e, auth, sizeof(auth));
        mg_printf(c,
            "GET /v2/orders/%s HTTP/1.1\r\n"
            "Host: %s\r\n"
            "%s"
            "Connection: close\r\n"
            "\r\n",
            p->id, ALPACA_HOST, auth);
        p->query_in_flight = 1;
    }
}
