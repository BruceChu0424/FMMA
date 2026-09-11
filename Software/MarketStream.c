/*
 * FMMA - FPGA Market Maker Accelerator
 * HPS-side application: market data -> FPGA -> order execution
 *
 * Runs on the DE1-SoC's ARM Cortex-A9 under Linux and owns everything
 * that is not a trading decision:
 *
 *   Coinbase WebSocket (BTC-USD ticker)
 *     -> parsed into fixed point here
 *     -> published into the shared on-chip RAM through the lightweight
 *        HPS-to-FPGA bridge, using the seqlock in docs/07
 *     -> the custom CPU in the FPGA fabric runs trading.asm and
 *        publishes a signal
 *     -> this program executes it as a paper order on Alpaca and
 *        reports the fill back so the CPU's inventory stays right
 *
 * The decision itself is deliberately NOT made here.  The whole point
 * of the project is that the fabric decides; this program measures how
 * long that takes and compares it against doing the same arithmetic in
 * software (--bench).
 *
 * Build: see Software/Makefile.  TLS matters - mongoose's built-in TLS
 * stack cannot complete a handshake with Coinbase (it rejects P-384
 * intermediates), so the Makefile builds against OpenSSL.
 *
 * Credentials come from the environment, never from the source:
 *   export APCA_API_KEY_ID=...
 *   export APCA_API_SECRET_KEY=...
 */

#include "mongoose.h"
#include "fmma_protocol.h"
#include "fpga_program.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/mman.h>

/* ------------------------------------------------------------------ */
/* Configuration                                                       */
/* ------------------------------------------------------------------ */

/* Base address of the lightweight HPS-to-FPGA bridge on Cyclone V.
 * The shared RAM is the only slave on it and sits at offset 0, which
 * is what the Qsys connection hps_0.h2f_lw_axi_master -> s1 with
 * baseAddress 0x0000 means. */
#define LW_H2F_BASE   0xFF200000UL
#define MAP_SIZE      (FMMA_MEM_WORDS * 4u)

#define COINBASE_URL  "wss://ws-feed.exchange.coinbase.com"
#define COINBASE_HOST "ws-feed.exchange.coinbase.com"
#define ALPACA_URL    "https://paper-api.alpaca.markets/v2/orders"
#define ALPACA_HOST   "paper-api.alpaca.markets"

/* Certificate authorities. Without a trust anchor TLS only checks the
 * host name, which stops nothing. Debian/Ubuntu and the Cyclone V
 * images put the bundle in one of these. */
static const char *s_ca_candidates[] = {
    "/etc/ssl/certs/ca-certificates.crt",
    "/etc/pki/tls/certs/ca-bundle.crt",
    "/etc/ssl/cert.pem",
    NULL
};

struct config {
    const char *product;        /* Coinbase product id, e.g. BTC-USD      */
    const char *symbol;         /* Alpaca symbol, e.g. BTCUSD             */
    const char *qty;            /* order size as a string, e.g. "0.001"   */
    const char *ca_file;        /* CA bundle, NULL = autodetect           */
    unsigned    threshold;      /* CFG_THRESH, price units (cents)        */
    unsigned    max_position;   /* CFG_MAX_POS, lots                      */
    long        start_position; /* CFG_POSITION, lots (signed)            */
    unsigned    poll_ms;        /* how often the network loop runs        */
    unsigned    stats_sec;      /* statistics interval, 0 = off           */
    unsigned    cooldown_ms;    /* minimum spacing between orders         */
    int         use_fpga;       /* 0 = software-only mode                 */
    int         dry_run;        /* 1 = never send an order                */
    int         bench;          /* 1 = also time the software strategy    */
    int         verbose;
};

static struct config g_cfg = {
    .product        = "BTC-USD",
    .symbol         = "BTCUSD",
    .qty            = "0.001",
    .ca_file        = NULL,
    .threshold      = 1000,      /* $10.00 in cents */
    .max_position   = 5,
    .start_position = 0,
    .poll_ms        = 1,
    .stats_sec      = 30,
    .cooldown_ms    = 1000,
    .use_fpga       = 1,
    .dry_run        = 0,
    .bench          = 0,
    .verbose        = 0,
};

/* ------------------------------------------------------------------ */
/* State                                                               */
/* ------------------------------------------------------------------ */

static volatile unsigned int *g_regs = NULL;   /* window onto the shared RAM */
static void         *g_map      = MAP_FAILED;
static int           g_mem_fd   = -1;
static struct mg_mgr g_mgr;
static volatile sig_atomic_t g_stop = 0;

static const char *g_alpaca_key    = NULL;
static const char *g_alpaca_secret = NULL;

static unsigned g_tick_seq   = 0;    /* even value last published        */
static unsigned g_signal_seq = 0;    /* last SIGNAL_SEQ acted on         */
static unsigned g_fill_seq   = 0;    /* last FILL_SEQ we published       */
static unsigned g_heartbeat  = 0;

static struct mg_connection *g_feed = NULL;
static uint64_t g_reconnect_at = 0;
static unsigned g_reconnect_backoff_ms = 500;

/* Publish time of each tick, so a signal can be matched back to the
 * quote that caused it.  Indexed by tick sequence number; 256 entries
 * is far more than the handful of ticks that can be in flight. */
#define TICK_HISTORY 256
static uint64_t g_tick_time_us[TICK_HISTORY];

struct stats {
    unsigned long ticks, signals, orders, rejected, errors, torn;
    uint64_t lat_sum_us, lat_max_us, lat_min_us;
    uint64_t sw_sum_ns, sw_max_ns;
    unsigned long sw_count;
};
static struct stats g_stats = { .lat_min_us = (uint64_t) -1 };

/* ------------------------------------------------------------------ */
/* Small helpers                                                       */
/* ------------------------------------------------------------------ */

static uint64_t now_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t) ts.tv_sec * 1000000ull + (uint64_t) ts.tv_nsec / 1000ull;
}

static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t) ts.tv_sec * 1000000000ull + (uint64_t) ts.tv_nsec;
}

/* Order the accesses to the shared RAM.  The bridge window is mapped
 * with O_SYNC so it is device memory and the CPU will not reorder the
 * stores itself, but the compiler happily would, and the seqlock's
 * correctness is entirely about store order. */
static inline void fmma_barrier(void) {
    __sync_synchronize();
}

static void on_signal(int sig) {
    (void) sig;
    g_stop = 1;
}

/* ------------------------------------------------------------------ */
/* Fixed-point parsing                                                 */
/* ------------------------------------------------------------------ */

/* Parse a JSON decimal string such as "97432.17" into an integer
 * scaled by `scale`, without going through a float.
 *
 * The previous version used strtof() and multiplied by 10000.  A float
 * carries 24 bits of mantissa; a BTC price scaled by 10000 needs 30, so
 * the bottom six bits were noise - the four decimal places the protocol
 * advertised were not actually delivered.  Integer parsing is exact and
 * cheaper.
 *
 * Returns -1 if `s` does not start with a number. */
static long parse_scaled(const char *s, unsigned scale) {
    const char *p = s;
    int neg = 0;
    long whole = 0, frac = 0;
    unsigned div = 1;

    if (*p == '-') { neg = 1; p++; }
    else if (*p == '+') { p++; }
    if (*p < '0' || *p > '9') return -1;

    while (*p >= '0' && *p <= '9') {
        if (whole < 100000000L)              /* saturate rather than wrap */
            whole = whole * 10 + (*p - '0');
        p++;
    }
    if (*p == '.') {
        p++;
        while (*p >= '0' && *p <= '9') {
            if (div < scale) {
                frac = frac * 10 + (*p - '0');
                div *= 10;
            }
            p++;
        }
    }
    while (div < scale) { frac *= 10; div *= 10; }

    long v = whole * (long) scale + frac;
    return neg ? -v : v;
}

/* Extract the value of a JSON string field: "name":"<value>".
 * Returns a pointer into `json` or NULL. Only the flat top-level
 * objects Coinbase sends are handled, which is all this needs. */
static const char *json_str_field(const char *json, const char *name) {
    char pattern[64];
    int n = snprintf(pattern, sizeof(pattern), "\"%s\":\"", name);
    if (n <= 0 || (size_t) n >= sizeof(pattern)) return NULL;
    const char *p = strstr(json, pattern);
    return p ? p + n : NULL;
}

/* Does this message have "type":"<want>"? strstr("\"ticker\"") would
 * also match a "last_match" or a channel list, so match the field. */
static int json_type_is(const char *json, const char *want) {
    const char *p = json_str_field(json, "type");
    if (!p) return 0;
    size_t n = strlen(want);
    return strncmp(p, want, n) == 0 && p[n] == '"';
}

/* Clamp to what the CPU's signed comparisons can represent.  The
 * strategy adds bid and ask together, so each side must stay below
 * 2^30 for the sum to stay positive. */
#define FMMA_PRICE_MAX 0x3FFFFFFFL

static unsigned clamp_price(long v, const char *what) {
    if (v < 0) {
        printf("[MARKET] negative %s (%ld), ignoring\n", what, v);
        return 0;
    }
    if (v > FMMA_PRICE_MAX) {
        printf("[MARKET] %s %ld exceeds the fixed-point range, clamping\n", what, v);
        g_stats.errors++;
        return (unsigned) FMMA_PRICE_MAX;
    }
    return (unsigned) v;
}

/* ------------------------------------------------------------------ */
/* Shared-memory protocol: the HPS half                                */
/* ------------------------------------------------------------------ */

static void fpga_write(unsigned word, unsigned value) {
    if (g_regs) g_regs[word] = value;
}

static unsigned fpga_read(unsigned word) {
    return g_regs ? g_regs[word] : 0u;
}

/* Publish one market-data snapshot.  TICK_SEQ is odd while the block
 * is being written and even when it is consistent, which is what lets
 * the CPU tell a whole snapshot from a half-written one. */
static void publish_tick(unsigned bid, unsigned ask,
                         unsigned bid_size, unsigned ask_size) {
    if (!g_regs) return;

    unsigned odd = g_tick_seq + 1;
    fpga_write(FMMA_TICK_SEQ, odd);          /* writer in progress */
    fmma_barrier();

    fpga_write(FMMA_BID, bid);
    fpga_write(FMMA_ASK, ask);
    fpga_write(FMMA_BID_SIZE, bid_size);
    fpga_write(FMMA_ASK_SIZE, ask_size);
    fmma_barrier();

    g_tick_seq = odd + 1;                    /* snapshot is stable */
    fpga_write(FMMA_TICK_SEQ, g_tick_seq);

    g_tick_time_us[g_tick_seq % TICK_HISTORY] = now_us();
    g_stats.ticks++;
}

/* Tell the CPU about a fill so its inventory - and therefore its risk
 * limit - stays in step with the broker. */
static void report_fill(unsigned side, unsigned qty) {
    if (!g_regs) return;
    fpga_write(FMMA_FILL_SIDE, side);
    fpga_write(FMMA_FILL_QTY, qty);
    fmma_barrier();
    g_fill_seq++;
    fpga_write(FMMA_FILL_SEQ, g_fill_seq);   /* published last */
}

static void push_config(void) {
    if (!g_regs) return;
    fpga_write(FMMA_CFG_THRESH, g_cfg.threshold);
    fpga_write(FMMA_CFG_MAX_POS, g_cfg.max_position);
    fpga_write(FMMA_CFG_POSITION, (unsigned) g_cfg.start_position);
    fpga_write(FMMA_CFG_HALF_SPREAD, 0);
    fpga_write(FMMA_CFG_SKEW, 0);
}

/* ------------------------------------------------------------------ */
/* Loader                                                              */
/* ------------------------------------------------------------------ */

/*
 * Writing the program is not as simple as a memcpy, because the CPU is
 * running the whole time: there is no reset line from the HPS into the
 * fabric.  Two things make it safe:
 *
 *  - Trading is disabled first, so nothing the half-written image does
 *    can reach the broker.
 *  - Word PROGRAM_BASE is written LAST.  Until it lands, the word the
 *    PC points at is still whatever was there before; on a freshly
 *    configured FPGA that is zero, which is the CPU's halt instruction.
 *    So a freshly configured CPU cannot start on a partial image.
 *
 * If a previous program is already running, CFG_RESTART brings it back
 * to the top of the new image.  If the CPU is wedged (no heartbeat),
 * KEY[0] on the board is the hardware way out.
 */
static int load_fpga_program(void) {
    if (!g_regs) return -1;

    if (FPGA_PROGRAM_BASE != FMMA_PROGRAM_BASE) {
        printf("[LOADER] ERROR: program assembled for word %u but the protocol "
               "says %u - re-run the assembler.\n",
               FPGA_PROGRAM_BASE, FMMA_PROGRAM_BASE);
        return -1;
    }
    if (FPGA_PROGRAM_BASE + FPGA_PROGRAM_LEN > FMMA_PROGRAM_LIMIT) {
        printf("[LOADER] ERROR: program is %u words at %u, which runs past the "
               "program area (ends at %u).\n",
               FPGA_PROGRAM_LEN, FPGA_PROGRAM_BASE, FMMA_PROGRAM_LIMIT);
        return -1;
    }

    printf("[LOADER] Disabling trading while the image is replaced.\n");
    fpga_write(FMMA_CFG_ENABLE, 0);
    fpga_write(FMMA_CFG_RESTART, 0);
    push_config();
    fmma_barrier();

    printf("[LOADER] Writing %u program words at word %u (entry word last).\n",
           FPGA_PROGRAM_LEN, FPGA_PROGRAM_BASE);
    for (unsigned i = 1; i < FPGA_PROGRAM_LEN; i++)
        g_regs[FPGA_PROGRAM_BASE + i] = fpga_program[i];
    fmma_barrier();
    g_regs[FPGA_PROGRAM_BASE] = fpga_program[0];
    fmma_barrier();

    for (unsigned i = 0; i < FPGA_PROGRAM_LEN; i++) {
        unsigned got = g_regs[FPGA_PROGRAM_BASE + i];
        if (got != fpga_program[i]) {
            printf("[LOADER] ERROR: readback mismatch at word %u: "
                   "wrote 0x%08X, read 0x%08X.\n",
                   FPGA_PROGRAM_BASE + i, fpga_program[i], got);
            printf("[LOADER] The bridge window (0x%lX) is probably not the "
                   "shared RAM, or the FPGA is not configured.\n", LW_H2F_BASE);
            return -1;
        }
    }
    printf("[LOADER] Program verified.\n");
    return 0;
}

/* Ask the CPU to re-enter its initialisation block and wait until it
 * says it is running the protocol version we were built against. */
static int start_cpu(void) {
    if (!g_regs) return -1;

    fpga_write(FMMA_FW_VERSION, 0);       /* so a stale value cannot fool us */
    fmma_barrier();
    fpga_write(FMMA_CFG_RESTART, 1);

    printf("[LOADER] Waiting for the CPU...\n");
    unsigned last_beat = fpga_read(FMMA_HEARTBEAT);
    for (int i = 0; i < 50; i++) {        /* up to ~5 s */
        usleep(100000);
        unsigned version = fpga_read(FMMA_FW_VERSION);
        unsigned beat    = fpga_read(FMMA_HEARTBEAT);
        if (version == FMMA_PROTOCOL_VERSION && beat != last_beat) {
            g_heartbeat  = beat;
            g_signal_seq = fpga_read(FMMA_SIGNAL_SEQ);
            printf("[LOADER] CPU running: protocol v%u, heartbeat %u, "
                   "position %d.\n", version, beat,
                   (int) fpga_read(FMMA_POSITION));
            return 0;
        }
        if (version != 0 && version != FMMA_PROTOCOL_VERSION) {
            printf("[LOADER] ERROR: the CPU reports protocol v%u but this "
                   "program speaks v%u. Rebuild both from the same tree.\n",
                   version, FMMA_PROTOCOL_VERSION);
            return -1;
        }
    }

    printf("[LOADER] ERROR: no heartbeat.\n");
    printf("[LOADER]   - Is output_files/HFTTop.sof programmed?\n");
    printf("[LOADER]   - If a previous program is wedged, press KEY[0] on the\n");
    printf("[LOADER]     board to reset the CPU, then run this again.\n");
    return -1;
}

/* ------------------------------------------------------------------ */
/* Alpaca execution                                                    */
/* ------------------------------------------------------------------ */

struct order_ctx {
    unsigned side;              /* FMMA_SIGNAL_BUY / FMMA_SIGNAL_SELL */
    uint64_t sent_us;
};

static unsigned long g_last_order_ms = 0;

static const char *pick_ca_file(void) {
    if (g_cfg.ca_file) return g_cfg.ca_file;
    for (int i = 0; s_ca_candidates[i]; i++)
        if (access(s_ca_candidates[i], R_OK) == 0) return s_ca_candidates[i];
    return NULL;
}

static void tls_start(struct mg_connection *c, const char *host) {
    struct mg_tls_opts opts;
    memset(&opts, 0, sizeof(opts));
    const char *ca = pick_ca_file();
    if (ca) opts.ca = mg_file_read(&mg_fs_posix, ca);
    opts.name = mg_str(host);
    mg_tls_init(c, &opts);
}

static void alpaca_cb(struct mg_connection *c, int ev, void *ev_data) {
    struct order_ctx *ctx = (struct order_ctx *) c->fn_data;

    if (ev == MG_EV_CONNECT) {
        tls_start(c, ALPACA_HOST);
    } else if (ev == MG_EV_HTTP_MSG) {
        struct mg_http_message *hm = (struct mg_http_message *) ev_data;
        int status = mg_http_status(hm);
        uint64_t rtt = ctx ? (now_us() - ctx->sent_us) / 1000 : 0;

        if (status >= 200 && status < 300) {
            printf("[ALPACA] accepted (HTTP %d, %llu ms)\n",
                   status, (unsigned long long) rtt);
            g_stats.orders++;
            /* Paper market orders are accepted and filled immediately.
             * We report the acceptance as a fill so the CPU's inventory
             * tracks the broker; docs/09 explains why that is the right
             * approximation here and what would replace it in a system
             * that had to handle partial fills. */
            if (ctx) report_fill(ctx->side == FMMA_SIGNAL_BUY
                                 ? FMMA_FILL_BOUGHT : FMMA_FILL_SOLD, 1);
        } else {
            printf("[ALPACA] REJECTED (HTTP %d): %.*s\n", status,
                   (int) hm->body.len, hm->body.buf);
            g_stats.rejected++;
        }
        c->is_draining = 1;
    } else if (ev == MG_EV_ERROR) {
        printf("[ALPACA] connection error: %s\n", (char *) ev_data);
        g_stats.errors++;
    } else if (ev == MG_EV_CLOSE) {
        free(ctx);
        c->fn_data = NULL;
    }
}

static void send_order(unsigned side) {
    const char *side_str = (side == FMMA_SIGNAL_BUY) ? "buy" : "sell";
    unsigned long now = (unsigned long) (now_us() / 1000);

    if (now - g_last_order_ms < g_cfg.cooldown_ms) {
        printf("[EXEC] cooldown active, dropping %s\n", side_str);
        g_stats.rejected++;
        return;
    }
    if (g_cfg.dry_run) {
        printf("[EXEC] dry run: would send %s %s %s\n",
               side_str, g_cfg.qty, g_cfg.symbol);
        g_last_order_ms = now;
        return;
    }
    if (!g_alpaca_key || !g_alpaca_secret) {
        printf("[EXEC] APCA_API_KEY_ID / APCA_API_SECRET_KEY are not set, "
               "skipping %s\n", side_str);
        g_stats.rejected++;
        return;
    }

    struct order_ctx *ctx = (struct order_ctx *) calloc(1, sizeof(*ctx));
    if (!ctx) return;
    ctx->side = side;
    ctx->sent_us = now_us();

    struct mg_connection *c = mg_http_connect(&g_mgr, ALPACA_URL, alpaca_cb, ctx);
    if (!c) {
        printf("[EXEC] could not open a connection to Alpaca\n");
        free(ctx);
        g_stats.errors++;
        return;
    }

    char body[256];
    int blen = snprintf(body, sizeof(body),
        "{\"symbol\":\"%s\",\"qty\":\"%s\",\"side\":\"%s\","
        "\"type\":\"market\",\"time_in_force\":\"gtc\"}",
        g_cfg.symbol, g_cfg.qty, side_str);

    mg_printf(c,
        "POST /v2/orders HTTP/1.1\r\n"
        "Host: %s\r\n"
        "Content-Type: application/json\r\n"
        "Content-Length: %d\r\n"
        "APCA-API-KEY-ID: %s\r\n"
        "APCA-API-SECRET-KEY: %s\r\n"
        "Connection: close\r\n"
        "\r\n%s",
        ALPACA_HOST, blen, g_alpaca_key, g_alpaca_secret, body);

    printf("*** [EXEC] %s %s %s ***\n", side_str, g_cfg.qty, g_cfg.symbol);
    g_last_order_ms = now;
}

/* ------------------------------------------------------------------ */
/* Reading the CPU's decisions                                         */
/* ------------------------------------------------------------------ */

/*
 * SIGNAL_SEQ is the handshake.  The CPU writes SIGNAL and SIGNAL_TICK
 * and only then increments SIGNAL_SEQ, so a new sequence number means
 * the words describing it are already in memory.  This side never
 * writes into the output block at all, which is what removes the
 * lost-signal race the previous protocol had: there, the HPS cleared
 * SIGNAL after acting and could wipe a decision the CPU had raised in
 * between.
 */
static void poll_fpga(void) {
    if (!g_regs) return;

    unsigned beat = fpga_read(FMMA_HEARTBEAT);
    if (beat != g_heartbeat) g_heartbeat = beat;

    unsigned seq = fpga_read(FMMA_SIGNAL_SEQ);
    if (seq == g_signal_seq) return;

    unsigned side = fpga_read(FMMA_SIGNAL);
    unsigned tick = fpga_read(FMMA_SIGNAL_TICK);
    unsigned missed = seq - g_signal_seq - 1;
    g_signal_seq = seq;
    g_stats.signals++;

    uint64_t published = g_tick_time_us[tick % TICK_HISTORY];
    uint64_t latency = published ? now_us() - published : 0;
    if (latency) {
        g_stats.lat_sum_us += latency;
        if (latency > g_stats.lat_max_us) g_stats.lat_max_us = latency;
        if (latency < g_stats.lat_min_us) g_stats.lat_min_us = latency;
    }

    if (missed)
        printf("[FPGA] %u signal(s) arrived faster than this loop could read "
               "them\n", missed);

    printf(">>> [FPGA] %s  (tick %u, %llu us after the quote was published, "
           "position %d)\n",
           side == FMMA_SIGNAL_BUY ? "BUY" : side == FMMA_SIGNAL_SELL ? "SELL"
                                                                      : "???",
           tick, (unsigned long long) latency, (int) fpga_read(FMMA_POSITION));

    if (side == FMMA_SIGNAL_BUY || side == FMMA_SIGNAL_SELL)
        send_order(side);
    else
        printf("[FPGA] unknown signal value %u, ignoring\n", side);
}

/* ------------------------------------------------------------------ */
/* Software reference strategy (for the latency comparison)            */
/* ------------------------------------------------------------------ */

/*
 * The same decision the CPU makes, in C, so --bench can report what the
 * fabric buys us.  This is the honest comparison: it measures only the
 * arithmetic, not the bus traffic, which is the part an FPGA cannot
 * help with.  See docs/14.
 */
static long  g_sw_anchor = 0;
static int   g_sw_position = 0;

static unsigned software_decide(unsigned bid, unsigned ask) {
    long sum = (long) bid + (long) ask;
    long band = 2L * (long) g_cfg.threshold;
    unsigned decision = FMMA_SIGNAL_NONE;

    if (bid == 0 || ask == 0) return FMMA_SIGNAL_NONE;
    if (g_sw_anchor == 0) { g_sw_anchor = sum; return FMMA_SIGNAL_NONE; }

    if (sum < g_sw_anchor - band) {
        decision = (g_sw_position < (int) g_cfg.max_position)
                 ? FMMA_SIGNAL_BUY : FMMA_SIGNAL_NONE;
        g_sw_anchor = sum;
    } else if (sum > g_sw_anchor + band) {
        decision = (g_sw_position > -(int) g_cfg.max_position)
                 ? FMMA_SIGNAL_SELL : FMMA_SIGNAL_NONE;
        g_sw_anchor = sum;
    } else {
        g_sw_anchor = sum;
    }
    return decision;
}

static void bench_software(unsigned bid, unsigned ask) {
    uint64_t t0 = now_ns();
    unsigned d = software_decide(bid, ask);
    uint64_t dt = now_ns() - t0;
    (void) d;
    g_stats.sw_sum_ns += dt;
    g_stats.sw_count++;
    if (dt > g_stats.sw_max_ns) g_stats.sw_max_ns = dt;
}

/* ------------------------------------------------------------------ */
/* Coinbase feed                                                       */
/* ------------------------------------------------------------------ */

static void handle_ticker(const char *json) {
    const char *bid_s = json_str_field(json, "best_bid");
    const char *ask_s = json_str_field(json, "best_ask");
    if (!bid_s || !ask_s) return;

    long bid = parse_scaled(bid_s, FMMA_PRICE_SCALE);
    long ask = parse_scaled(ask_s, FMMA_PRICE_SCALE);
    if (bid < 0 || ask < 0) return;

    /* Sizes are fractional (0.0013 BTC), so they carry their own scale
     * rather than being truncated to an integer number of coins - which
     * is what the previous version did, making every size zero. */
    const char *bsz_s = json_str_field(json, "best_bid_size");
    const char *asz_s = json_str_field(json, "best_ask_size");
    long bsz = bsz_s ? parse_scaled(bsz_s, 10000) : 0;
    long asz = asz_s ? parse_scaled(asz_s, 10000) : 0;

    unsigned bid_i = clamp_price(bid, "bid");
    unsigned ask_i = clamp_price(ask, "ask");
    if (!bid_i || !ask_i) return;

    if (g_cfg.verbose)
        printf("[MARKET] bid %ld.%02u  ask %ld.%02u\n",
               bid / FMMA_PRICE_SCALE, (unsigned) (bid % FMMA_PRICE_SCALE),
               ask / FMMA_PRICE_SCALE, (unsigned) (ask % FMMA_PRICE_SCALE));

    if (g_cfg.bench) bench_software(bid_i, ask_i);

    if (g_regs) {
        publish_tick(bid_i, ask_i,
                     (unsigned) (bsz < 0 ? 0 : bsz),
                     (unsigned) (asz < 0 ? 0 : asz));
        poll_fpga();
    } else {
        /* Software-only mode: no fabric, so this side decides. */
        unsigned d = software_decide(bid_i, ask_i);
        if (d != FMMA_SIGNAL_NONE) {
            printf(">>> [SOFTWARE] %s\n", d == FMMA_SIGNAL_BUY ? "BUY" : "SELL");
            send_order(d);
        }
        g_stats.ticks++;
    }
}

static void schedule_reconnect(void) {
    g_feed = NULL;
    g_reconnect_at = now_us() + (uint64_t) g_reconnect_backoff_ms * 1000ull;
    printf("[FEED] reconnecting in %u ms\n", g_reconnect_backoff_ms);
    g_reconnect_backoff_ms *= 2;
    if (g_reconnect_backoff_ms > 30000) g_reconnect_backoff_ms = 30000;
}

static void coinbase_cb(struct mg_connection *c, int ev, void *ev_data) {
    if (ev == MG_EV_CONNECT) {
        tls_start(c, COINBASE_HOST);
    } else if (ev == MG_EV_WS_OPEN) {
        char sub[256];
        snprintf(sub, sizeof(sub),
                 "{\"type\":\"subscribe\",\"product_ids\":[\"%s\"],"
                 "\"channels\":[\"ticker\"]}", g_cfg.product);
        mg_ws_send(c, sub, strlen(sub), WEBSOCKET_OP_TEXT);
        printf("[FEED] connected, subscribed to %s ticker\n", g_cfg.product);
        g_reconnect_backoff_ms = 500;      /* a good connection resets it */
    } else if (ev == MG_EV_WS_MSG) {
        struct mg_ws_message *wm = (struct mg_ws_message *) ev_data;
        char stack[2048];
        char *buf = stack;
        if (wm->data.len + 1 > sizeof(stack)) {
            buf = (char *) malloc(wm->data.len + 1);
            if (!buf) return;
        }
        memcpy(buf, wm->data.buf, wm->data.len);
        buf[wm->data.len] = '\0';

        if (json_type_is(buf, "ticker"))
            handle_ticker(buf);
        else if (json_type_is(buf, "error"))
            printf("[FEED] Coinbase error: %s\n", buf);

        if (buf != stack) free(buf);
    } else if (ev == MG_EV_ERROR) {
        printf("[FEED] error: %s\n", (char *) ev_data);
        g_stats.errors++;
    } else if (ev == MG_EV_CLOSE) {
        printf("[FEED] disconnected\n");
        schedule_reconnect();
    }
}

static void connect_feed(void) {
    g_feed = mg_ws_connect(&g_mgr, COINBASE_URL, coinbase_cb, NULL, NULL);
    if (!g_feed) {
        printf("[FEED] could not start a connection\n");
        schedule_reconnect();
    }
}

/* ------------------------------------------------------------------ */
/* Reporting                                                           */
/* ------------------------------------------------------------------ */

static void print_stats(uint64_t elapsed_us) {
    printf("\n--- %llu s: %lu ticks, %lu signals, %lu orders, %lu rejected, "
           "%lu errors ---\n",
           (unsigned long long) (elapsed_us / 1000000ull),
           g_stats.ticks, g_stats.signals, g_stats.orders,
           g_stats.rejected, g_stats.errors);

    if (g_stats.signals && g_stats.lat_min_us != (uint64_t) -1)
        printf("    quote -> decision seen: min %llu us, mean %llu us, "
               "max %llu us\n",
               (unsigned long long) g_stats.lat_min_us,
               (unsigned long long) (g_stats.lat_sum_us / g_stats.signals),
               (unsigned long long) g_stats.lat_max_us);

    if (g_regs) {
        unsigned status = fpga_read(FMMA_STATUS);
        printf("    FPGA: heartbeat %u, position %d, rejects %u, status 0x%X%s%s\n",
               fpga_read(FMMA_HEARTBEAT), (int) fpga_read(FMMA_POSITION),
               fpga_read(FMMA_REJECTS), status,
               (status & FMMA_STATUS_RISK_BLOCKED) ? " [risk-blocked]" : "",
               (status & FMMA_STATUS_DISABLED) ? " [disabled]" : "");
    }

    if (g_cfg.bench && g_stats.sw_count)
        printf("    software strategy: mean %llu ns, max %llu ns over %lu ticks\n",
               (unsigned long long) (g_stats.sw_sum_ns / g_stats.sw_count),
               (unsigned long long) g_stats.sw_max_ns, g_stats.sw_count);
}

/* ------------------------------------------------------------------ */
/* Startup / teardown                                                  */
/* ------------------------------------------------------------------ */

static int map_bridge(void) {
    g_mem_fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (g_mem_fd == -1) {
        printf("Could not open /dev/mem (%s).\n", strerror(errno));
        printf("Run with sudo, or pass --no-fpga to run the software-only "
               "reference.\n");
        return -1;
    }
    g_map = mmap(NULL, MAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED,
                 g_mem_fd, LW_H2F_BASE);
    if (g_map == MAP_FAILED) {
        printf("mmap of 0x%lX failed (%s).\n", LW_H2F_BASE, strerror(errno));
        close(g_mem_fd);
        g_mem_fd = -1;
        return -1;
    }
    g_regs = (volatile unsigned int *) g_map;
    printf("Shared RAM mapped at 0x%lX (%u words).\n",
           LW_H2F_BASE, FMMA_MEM_WORDS);
    return 0;
}

static void cleanup(void) {
    if (g_regs) {
        fpga_write(FMMA_CFG_ENABLE, 0);       /* stop the CPU trading */
        fmma_barrier();
    }
    mg_mgr_free(&g_mgr);
    if (g_map != MAP_FAILED) munmap(g_map, MAP_SIZE);
    if (g_mem_fd != -1) close(g_mem_fd);
    g_regs = NULL;
}

static void usage(const char *argv0) {
    printf(
"FMMA market data bridge - Coinbase -> FPGA -> Alpaca\n"
"\n"
"Usage: %s [options]\n"
"\n"
"  --no-fpga           run the software reference strategy instead of using\n"
"                      the fabric (no /dev/mem, no root needed)\n"
"  --dry-run           never send an order; log what would have been sent\n"
"  --bench             also time the software strategy, for comparison\n"
"  --product ID        Coinbase product id (default %s)\n"
"  --symbol SYM        Alpaca symbol (default %s)\n"
"  --qty Q             order size (default %s)\n"
"  --threshold CENTS   move that triggers a decision (default %u = $%.2f)\n"
"  --max-pos N         inventory limit in lots (default %u)\n"
"  --position N        inventory the CPU should start from (default %ld)\n"
"  --cooldown MS       minimum spacing between orders (default %u)\n"
"  --poll-ms MS        network/FPGA poll interval (default %u)\n"
"  --stats SEC         statistics interval, 0 to disable (default %u)\n"
"  --ca FILE           CA bundle for TLS (default: autodetect)\n"
"  -v, --verbose       print every quote\n"
"  -h, --help          this text\n"
"\n"
"Credentials come from APCA_API_KEY_ID and APCA_API_SECRET_KEY.\n",
    argv0, g_cfg.product, g_cfg.symbol, g_cfg.qty,
    g_cfg.threshold, g_cfg.threshold / 100.0, g_cfg.max_position,
    g_cfg.start_position, g_cfg.cooldown_ms, g_cfg.poll_ms, g_cfg.stats_sec);
}

static int parse_args(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        #define NEXT(var, conv) do {                                     \
            if (i + 1 >= argc) { printf("%s needs a value\n", a); return -1; } \
            var = conv(argv[++i]);                                       \
        } while (0)

        if (!strcmp(a, "--no-fpga")) g_cfg.use_fpga = 0;
        else if (!strcmp(a, "--dry-run")) g_cfg.dry_run = 1;
        else if (!strcmp(a, "--bench")) g_cfg.bench = 1;
        else if (!strcmp(a, "-v") || !strcmp(a, "--verbose")) g_cfg.verbose = 1;
        else if (!strcmp(a, "-h") || !strcmp(a, "--help")) { usage(argv[0]); return 1; }
        else if (!strcmp(a, "--product")) NEXT(g_cfg.product, );
        else if (!strcmp(a, "--symbol")) NEXT(g_cfg.symbol, );
        else if (!strcmp(a, "--qty")) NEXT(g_cfg.qty, );
        else if (!strcmp(a, "--ca")) NEXT(g_cfg.ca_file, );
        else if (!strcmp(a, "--threshold")) NEXT(g_cfg.threshold, (unsigned) atol);
        else if (!strcmp(a, "--max-pos")) NEXT(g_cfg.max_position, (unsigned) atol);
        else if (!strcmp(a, "--position")) NEXT(g_cfg.start_position, atol);
        else if (!strcmp(a, "--cooldown")) NEXT(g_cfg.cooldown_ms, (unsigned) atol);
        else if (!strcmp(a, "--poll-ms")) NEXT(g_cfg.poll_ms, (unsigned) atol);
        else if (!strcmp(a, "--stats")) NEXT(g_cfg.stats_sec, (unsigned) atol);
        else { printf("unknown option '%s' (try --help)\n", a); return -1; }
        #undef NEXT
    }
    if (g_cfg.poll_ms == 0) g_cfg.poll_ms = 1;
    return 0;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);

    int rc = parse_args(argc, argv);
    if (rc) return rc > 0 ? 0 : 2;

    printf("=== FMMA: %s -> FPGA -> Alpaca (protocol v%u) ===\n",
           g_cfg.product, FMMA_PROTOCOL_VERSION);

    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);

    g_alpaca_key    = getenv("APCA_API_KEY_ID");
    g_alpaca_secret = getenv("APCA_API_SECRET_KEY");
    if (!g_alpaca_key || !g_alpaca_secret)
        printf("NOTE: Alpaca credentials are not in the environment, so orders "
               "will be skipped.\n");
    if (!pick_ca_file())
        printf("WARNING: no CA bundle found; TLS will not be able to verify "
               "the server. Pass --ca /path/to/ca-certificates.crt.\n");

    if (g_cfg.use_fpga) {
        if (map_bridge() != 0) return 3;
        if (load_fpga_program() != 0) { cleanup(); return 4; }
        if (start_cpu() != 0) { cleanup(); return 5; }
        fpga_write(FMMA_CFG_ENABLE, g_cfg.dry_run ? 1 : 1);
        printf("Trading enabled: threshold %u cents, max position %u lots.\n",
               g_cfg.threshold, g_cfg.max_position);
    } else {
        printf("Software-only mode: the strategy runs on this CPU, the fabric "
               "is not used.\n");
    }

    mg_mgr_init(&g_mgr);
    mg_log_set(g_cfg.verbose ? MG_LL_ERROR : MG_LL_NONE);
    connect_feed();

    uint64_t started = now_us();
    uint64_t next_stats = started + (uint64_t) g_cfg.stats_sec * 1000000ull;

    while (!g_stop) {
        mg_mgr_poll(&g_mgr, (int) g_cfg.poll_ms);
        poll_fpga();                       /* act even when the feed is quiet */

        uint64_t t = now_us();
        if (!g_feed && g_reconnect_at && t >= g_reconnect_at) {
            g_reconnect_at = 0;
            connect_feed();
        }
        if (g_cfg.stats_sec && t >= next_stats) {
            print_stats(t - started);
            next_stats = t + (uint64_t) g_cfg.stats_sec * 1000000ull;
        }
    }

    printf("\nShutting down.\n");
    print_stats(now_us() - started);
    cleanup();
    return 0;
}
