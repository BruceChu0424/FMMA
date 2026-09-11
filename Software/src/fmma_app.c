#include "fmma_app.h"
#include "fmma_config.h"
#include "fmma_exec.h"
#include "fmma_feed.h"
#include "fmma_fpga.h"
#include "fmma_log.h"
#include "fmma_risk.h"
#include "fmma_socfpga.h"
#include "fmma_stats.h"
#include "fmma_strategy.h"
#include "fmma_time.h"
#include "fmma_tls.h"

#include "../fmma_protocol.h"
#include "../third_party/mongoose.h"

#include <signal.h>
#include <stdlib.h>
#include <string.h>

#define TAG "app"

static volatile sig_atomic_t s_stop;

struct fmma_app {
    const struct fmma_config *cfg;
    struct mg_mgr         mgr;
    struct fmma_fpga     *fpga;
    struct fmma_feed     *feed;
    struct fmma_exec     *exec;
    struct fmma_stats     stats;
    struct fmma_risk      risk;
    struct fmma_strategy  soft;

    int64_t  last_mid;          /* price units, for marking and fills  */
    uint64_t next_stats_us;
    int      stale_warned;
};

void fmma_app_stop(void) { s_stop = 1; }

/* ------------------------------------------------------------------ */
/* callbacks                                                           */
/* ------------------------------------------------------------------ */

/* A fill came back from the broker: tell the fabric and the P&L. */
static void on_fill(void *user, uint32_t side, uint32_t qty, int64_t price)
{
    struct fmma_app *a = (struct fmma_app *)user;
    fmma_risk_on_fill(&a->risk, side, qty, price);
    fmma_fpga_report_fill(a->fpga, side, qty);
    fmma_strategy_on_fill(&a->soft, side, qty);
}

/* Act on a decision, whoever made it. */
static void act_on(struct fmma_app *a, uint32_t side, const char *origin)
{
    enum fmma_risk_verdict v =
        fmma_risk_check(&a->risk, fmma_stats_feed_age_us(&a->stats));
    if (v != FMMA_RISK_OK) {
        FMMA_WARN(TAG, "%s %s suppressed: %s", origin,
                  side == FMMA_SIGNAL_BUY ? "BUY" : "SELL",
                  fmma_risk_verdict_text(v));
        if (v == FMMA_RISK_LOSS_LIMIT || v == FMMA_RISK_HALTED)
            fmma_fpga_set_enabled(a->fpga, 0);
        return;
    }
    fmma_exec_send(a->exec, side, a->last_mid);
}

/* A new quote arrived. */
static void on_quote(void *user, const struct fmma_quote *q)
{
    struct fmma_app *a = (struct fmma_app *)user;

    a->last_mid = ((int64_t)q->bid + (int64_t)q->ask) / 2;
    fmma_risk_mark(&a->risk, a->last_mid);
    a->stale_warned = 0;

    /* Time the software strategy alongside the fabric when asked. */
    if (a->cfg->bench) {
        struct fmma_strategy copy = a->soft;   /* do not disturb state */
        uint64_t t0 = fmma_now_ns();
        (void)fmma_strategy_on_quote(&copy, q->bid, q->ask);
        fmma_stats_software(&a->stats, fmma_now_ns() - t0);
    }

    if (fmma_fpga_present(a->fpga)) {
        uint32_t seq = fmma_fpga_publish_tick(a->fpga, q->bid, q->ask,
                                              q->bid_size, q->ask_size);
        fmma_stats_tick(&a->stats, seq);
    } else {
        /* No fabric: this CPU decides. */
        fmma_stats_tick(&a->stats, (uint32_t)a->stats.ticks);
        uint32_t side = fmma_strategy_on_quote(&a->soft, q->bid, q->ask);
        if (side != FMMA_SIGNAL_NONE) {
            FMMA_INFO(TAG, ">>> SOFTWARE %s",
                      side == FMMA_SIGNAL_BUY ? "BUY" : "SELL");
            act_on(a, side, "software");
        }
    }
}

/* Read whatever the fabric has decided since the last look. */
static void drain_fpga(struct fmma_app *a)
{
    struct fmma_signal sig;
    while (fmma_fpga_poll_signal(a->fpga, &sig)) {
        if (sig.missed) {
            a->stats.missed_signals += sig.missed;
            FMMA_WARN(TAG, "%u decision(s) arrived faster than this loop "
                           "could read them", sig.missed);
        }
        uint64_t latency = fmma_stats_signal(&a->stats, sig.tick);

        struct fmma_fpga_state st;
        fmma_fpga_read_state(a->fpga, &st);

        FMMA_INFO(TAG, ">>> FPGA %s  (tick %u, %llu us after the quote, "
                       "fabric position %d)",
                  sig.side == FMMA_SIGNAL_BUY  ? "BUY"  :
                  sig.side == FMMA_SIGNAL_SELL ? "SELL" : "?",
                  sig.tick, (unsigned long long)latency, st.position);

        if (sig.side == FMMA_SIGNAL_BUY || sig.side == FMMA_SIGNAL_SELL)
            act_on(a, sig.side, "fabric");
        else
            FMMA_WARN(TAG, "unknown signal value %u", sig.side);
    }
}

static void check_feed_age(struct fmma_app *a)
{
    if (a->cfg->stale_feed_ms == 0 || a->stale_warned) return;
    uint64_t age = fmma_stats_feed_age_us(&a->stats);
    if (age > (uint64_t)a->cfg->stale_feed_ms * 1000ull) {
        FMMA_WARN(TAG, "no quote for %llu s - trading is suspended until "
                       "the feed recovers",
                  (unsigned long long)(age / 1000000ull));
        a->stale_warned = 1;
    }
}

static void report(struct fmma_app *a)
{
    fmma_stats_report(&a->stats);
    fmma_risk_report(&a->risk);

    if (fmma_fpga_present(a->fpga)) {
        struct fmma_fpga_state st;
        fmma_fpga_read_state(a->fpga, &st);
        uint32_t loops = fmma_fpga_heartbeat_delta(a->fpga);
        fmma_print("  fabric: position %d   rejects %u   status 0x%X%s%s   "
                   "%u loops since the last report\n",
                   st.position, st.rejects, st.status,
                   (st.status & FMMA_STATUS_RISK_BLOCKED) ? " [risk-blocked]" : "",
                   (st.status & FMMA_STATUS_DISABLED) ? " [disabled]" : "",
                   loops);
    }
    fmma_print("  feed: %s   orders working: %u\n",
               fmma_feed_connected(a->feed) ? "connected" : "DOWN",
               fmma_exec_pending(a->exec));
}

/* ------------------------------------------------------------------ */
/* lifecycle                                                           */
/* ------------------------------------------------------------------ */

struct fmma_app *fmma_app_create(const struct fmma_config *cfg)
{
    struct fmma_app *a = calloc(1, sizeof(*a));
    if (a == NULL) return NULL;
    a->cfg = cfg;

    fmma_stats_init(&a->stats);
    fmma_risk_init(&a->risk, cfg->max_loss, cfg->stale_feed_ms,
                   cfg->start_position);
    fmma_strategy_init(&a->soft, cfg->threshold, cfg->max_position,
                       cfg->start_position);

    if (cfg->ca_file) fmma_tls_set_ca_file(cfg->ca_file);
    fmma_tls_check();

    if (cfg->use_fpga) {
        /* Never map the bridge without knowing the fabric is configured:
         * an access with no slave behind it hangs the whole board. */
        if (fmma_fabric_check(cfg->force) != 0) { free(a); return NULL; }

        a->fpga = fmma_fpga_open();
        if (a->fpga == NULL) { free(a); return NULL; }

        struct fmma_fpga_config fc = {
            .threshold      = cfg->threshold,
            .max_position   = cfg->max_position,
            .start_position = cfg->start_position,
            .half_spread    = cfg->half_spread,
            .skew           = cfg->skew,
        };
        if (fmma_fpga_load(a->fpga, &fc) != 0) {
            fmma_fpga_close(a->fpga);
            free(a);
            return NULL;
        }
        fmma_fpga_set_enabled(a->fpga, 1);
        FMMA_INFO(TAG, "trading enabled in the fabric");
    } else {
        FMMA_INFO(TAG, "software-only mode: the fabric is not used");
    }

    mg_mgr_init(&a->mgr);
    mg_log_set(cfg->verbose ? MG_LL_ERROR : MG_LL_NONE);

    a->exec = fmma_exec_create(&a->mgr, cfg, &a->stats, on_fill, a);
    a->feed = fmma_feed_create(&a->mgr, cfg->product, &a->stats, on_quote, a);
    if (a->exec == NULL || a->feed == NULL) {
        fmma_app_destroy(a);
        return NULL;
    }
    return a;
}

int fmma_app_run(struct fmma_app *a)
{
    fmma_feed_start(a->feed);
    a->next_stats_us = fmma_now_us() +
                       (uint64_t)a->cfg->stats_sec * 1000000ull;

    while (!s_stop) {
        mg_mgr_poll(&a->mgr, (int)a->cfg->poll_ms);

        /* Poll the fabric outside the network callback too, so a quiet
         * feed does not delay a decision the CPU has already made. */
        drain_fpga(a);
        fmma_exec_poll(a->exec);
        fmma_feed_poll(a->feed);
        check_feed_age(a);

        if (a->cfg->stats_sec) {
            uint64_t now = fmma_now_us();
            if (now >= a->next_stats_us) {
                report(a);
                a->next_stats_us = now +
                    (uint64_t)a->cfg->stats_sec * 1000000ull;
            }
        }
    }

    FMMA_INFO(TAG, "shutting down");
    report(a);
    return 0;
}

void fmma_app_destroy(struct fmma_app *a)
{
    if (a == NULL) return;
    if (a->feed) fmma_feed_destroy(a->feed);
    if (a->exec) fmma_exec_destroy(a->exec);
    mg_mgr_free(&a->mgr);
    if (a->fpga) fmma_fpga_close(a->fpga);   /* also disables trading */
    free(a);
}
