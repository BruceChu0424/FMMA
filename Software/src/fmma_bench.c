/*
 * fmma-bench - hardware-in-the-loop latency harness.
 *
 * The number this project exists to produce is "how long does the
 * fabric take to turn a quote into a decision, measured from the HPS".
 * Measuring it on the live feed works, but it is a poor experiment: the
 * sample rate is whatever the exchange happens to send, the prices
 * rarely move far enough to trade, and nothing is repeatable.
 *
 * So this drives the same protocol with a synthetic quote series that is
 * constructed to trade on every tick, and times each round trip:
 *
 *     publish tick  ->  CPU sees it  ->  CPU decides  ->  host polls it
 *
 * The same series is run through the software transcription of the
 * strategy on the ARM core, so the comparison asked for in
 * docs/14-latency-and-performance.md is against the same arithmetic on
 * the same board rather than a number from a different machine.
 *
 * No TLS, no network, no broker - it links against libc only, which
 * matters because the stock DE1-SoC image has no OpenSSL headers and
 * this must be runnable before that is solved.
 *
 *     fmma-bench                     1000 ticks, 1 ms apart
 *     fmma-bench --ticks 20000 --interval 200
 *     fmma-bench --no-load           keep the program already running
 *     fmma-bench --csv lat.csv       per-sample output
 */

#include "fmma_fpga.h"
#include "fmma_log.h"
#include "fmma_socfpga.h"
#include "fmma_stats.h"
#include "fmma_strategy.h"
#include "fmma_time.h"

#include "../fmma_protocol.h"

#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define TAG "bench"

/* How long to wait for the fabric before calling a tick unanswered.
 * The CPU's whole loop is tens of microseconds; 50 ms is four orders of
 * magnitude of headroom, so a timeout here means it is not running. */
#define ANSWER_TIMEOUT_US 50000u

static volatile sig_atomic_t g_stop;
static void on_sigint(int s) { (void)s; g_stop = 1; }

struct bench_opts {
    uint32_t ticks;        /* how many quotes to publish        */
    uint32_t interval_us;  /* gap between them                  */
    uint32_t threshold;    /* CFG_THRESH                        */
    uint32_t max_position; /* CFG_MAX_POS                       */
    uint32_t base_price;   /* centre of the synthetic series    */
    uint32_t spread;       /* ask - bid                         */
    int      load;         /* 0 = use the program already there */
    int      force;        /* skip the fabric-state check       */
    int      verbose;
    const char *csv;
};

static void defaults(struct bench_opts *o)
{
    memset(o, 0, sizeof(*o));
    o->ticks        = 1000;
    o->interval_us  = 1000;
    o->threshold    = 5;
    o->max_position = 10;
    o->base_price   = 50000 * FMMA_PRICE_SCALE;   /* a plausible BTC mid */
    o->spread       = 2 * FMMA_PRICE_SCALE;
    o->load         = 1;
}

static void usage(void)
{
    printf(
"fmma-bench - measure fabric decision latency (protocol v%u)\n\n"
"  --ticks N        quotes to publish            (default 1000)\n"
"  --interval US    microseconds between them    (default 1000)\n"
"  --threshold N    CFG_THRESH, price units      (default 5)\n"
"  --max-pos N      CFG_MAX_POS, lots            (default 10)\n"
"  --price N        centre price, price units    (default 5000000)\n"
"  --spread N       ask minus bid, price units   (default 200)\n"
"  --no-load        do not reload the CPU program\n"
"  --csv FILE       write one line per sample\n"
"  --force          map the bridge without the fabric-state check\n"
"  -v, --verbose\n",
        FMMA_PROTOCOL_VERSION);
}

static int parse_args(int argc, char **argv, struct bench_opts *o)
{
    defaults(o);
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        const char *v = (i + 1 < argc) ? argv[i + 1] : NULL;

        if (!strcmp(a, "-h") || !strcmp(a, "--help")) { usage(); return 1; }
        else if (!strcmp(a, "--no-load"))  o->load = 0;
        else if (!strcmp(a, "--force"))    o->force = 1;
        else if (!strcmp(a, "-v") || !strcmp(a, "--verbose")) o->verbose = 1;
        else if (!strcmp(a, "--csv") && v) { o->csv = v; i++; }
        else if (!strcmp(a, "--ticks") && v)     { o->ticks = strtoul(v, 0, 0); i++; }
        else if (!strcmp(a, "--interval") && v)  { o->interval_us = strtoul(v, 0, 0); i++; }
        else if (!strcmp(a, "--threshold") && v) { o->threshold = strtoul(v, 0, 0); i++; }
        else if (!strcmp(a, "--max-pos") && v)   { o->max_position = strtoul(v, 0, 0); i++; }
        else if (!strcmp(a, "--price") && v)     { o->base_price = strtoul(v, 0, 0); i++; }
        else if (!strcmp(a, "--spread") && v)    { o->spread = strtoul(v, 0, 0); i++; }
        else {
            fprintf(stderr, "unknown option: %s\n\n", a);
            usage();
            return -1;
        }
    }
    if (o->ticks == 0) o->ticks = 1;
    return 0;
}

/*
 * The synthetic series.
 *
 * The strategy re-anchors on every quote and trades when the mid moves
 * more than the threshold between consecutive quotes, so a square wave
 * one price unit beyond the band produces a decision on every tick and
 * alternates the side.  Alternating sides keep the position inside
 * +/-1 lot, which keeps the risk limit out of the measurement - the
 * subject here is latency, not the limit, and the limit has its own
 * tests.
 */
static void synth_quote(const struct bench_opts *o, uint32_t i,
                        uint32_t *bid, uint32_t *ask)
{
    uint32_t step = o->threshold + 1;
    uint32_t mid  = (i & 1u) ? o->base_price + step : o->base_price - step;
    *bid = mid - o->spread / 2;
    *ask = mid + o->spread / 2;
}

/*
 * Busy-poll for the answer to the tick we just published.
 *
 * Busy, not sleeping: a sleep would quantise the result to the
 * scheduler tick and swamp the thing being measured.  The loop is
 * bounded, so a CPU that is not running costs one timeout rather than a
 * hang.
 */
static int await_signal(struct fmma_fpga *f, struct fmma_signal *sig)
{
    uint64_t deadline = fmma_now_us() + ANSWER_TIMEOUT_US;
    do {
        if (fmma_fpga_poll_signal(f, sig)) return 1;
    } while (fmma_now_us() < deadline);
    return 0;
}

/* Loops the CPU completes in a second - an independent liveness figure
 * that also says how often it can look at the shared memory. */
static void report_loop_rate(struct fmma_fpga *f)
{
    (void)fmma_fpga_heartbeat_delta(f);       /* reset the baseline */
    sleep(1);
    uint32_t loops = fmma_fpga_heartbeat_delta(f);
    FMMA_INFO(TAG, "CPU idle loop rate: %u loops/s (%.1f us per loop)",
              loops, loops ? 1e6 / (double)loops : 0.0);
}

struct run_result {
    uint32_t published, answered, unanswered, mismatched;
};

/*
 * The strategy triggers on the move between consecutive quotes, so the
 * very first quote after a restart has nothing to compare against and
 * only sets the anchor.  That is correct behaviour, not a missed
 * decision, so prime both models with one quote before the clock
 * starts rather than recording a spurious timeout.
 */
static void prime(struct fmma_fpga *f, const struct bench_opts *o,
                  struct fmma_strategy *sw)
{
    uint32_t bid, ask;
    synth_quote(o, 0, &bid, &ask);
    fmma_strategy_on_quote(sw, bid, ask);
    fmma_fpga_publish_tick(f, bid, ask, 1, 1);

    /* Give the CPU a loop or two to consume it, then drop whatever it
     * published so the first measured tick is matched to its own
     * answer. */
    usleep(1000);
    struct fmma_signal discard;
    fmma_fpga_poll_signal(f, &discard);
}

static void run_ticks(struct fmma_fpga *f, const struct bench_opts *o,
                      struct fmma_stats *st, struct fmma_strategy *sw,
                      FILE *csv, struct run_result *r)
{
    memset(r, 0, sizeof(*r));
    prime(f, o, sw);

    /* Start at 1: tick 0 is the priming quote, already published. */
    for (uint32_t i = 1; i <= o->ticks && !g_stop; i++) {
        uint32_t bid, ask;
        synth_quote(o, i, &bid, &ask);

        /* The software reference, on the same quote, before the fabric
         * call so the two are not measuring each other's cache effects. */
        uint64_t t0 = fmma_now_ns();
        uint32_t sw_side = fmma_strategy_on_quote(sw, bid, ask);
        fmma_stats_software(st, fmma_now_ns() - t0);

        uint32_t seq = fmma_fpga_publish_tick(f, bid, ask, 1, 1);
        fmma_stats_tick(st, seq);
        r->published++;

        struct fmma_signal sig;
        if (!await_signal(f, &sig)) {
            r->unanswered++;
            if (r->unanswered <= 3)
                FMMA_WARN(TAG, "tick %u (seq %u) went unanswered for %u us",
                          i, seq, ANSWER_TIMEOUT_US);
            continue;
        }

        uint64_t us = fmma_stats_signal(st, sig.tick);
        st->signals++;
        r->answered++;

        /* The fabric and the transcription must agree, or the latency
         * figure is describing two different strategies. */
        if (sw_side != FMMA_SIGNAL_NONE && sw_side != sig.side)
            r->mismatched++;

        if (csv)
            fprintf(csv, "%u,%u,%u,%s,%llu\n", i, seq, sig.tick,
                    sig.side == FMMA_SIGNAL_BUY ? "BUY" : "SELL",
                    (unsigned long long)us);

        if (o->verbose)
            FMMA_DEBUG(TAG, "tick %u seq %u -> %s in %llu us", i, seq,
                       sig.side == FMMA_SIGNAL_BUY ? "BUY" : "SELL",
                       (unsigned long long)us);

        /* Close the loop: tell both models the order filled, so the
         * position tracks and the series keeps trading. */
        uint32_t fill = (sig.side == FMMA_SIGNAL_BUY) ? FMMA_FILL_BOUGHT
                                                      : FMMA_FILL_SOLD;
        fmma_fpga_report_fill(f, fill, 1);
        fmma_strategy_on_fill(sw, fill, 1);

        if (o->interval_us) usleep(o->interval_us);
    }
}

static void report(const struct bench_opts *o, const struct fmma_stats *st,
                   const struct run_result *r, struct fmma_fpga *f)
{
    struct fmma_fpga_state s;
    fmma_fpga_read_state(f, &s);

    printf("\n");
    printf("fabric decision latency, %u samples\n", (unsigned)st->lat_count);
    if (st->lat_count) {
        printf("  min   %6llu us\n", (unsigned long long)st->lat_min);
        printf("  mean  %6llu us\n",
               (unsigned long long)(st->lat_sum / st->lat_count));
        printf("  p99   %6llu us\n",
               (unsigned long long)fmma_stats_percentile(st, 0.99));
        printf("  max   %6llu us\n", (unsigned long long)st->lat_max);
    }

    printf("\nsoftware transcription on the ARM core, %u samples\n",
           (unsigned)st->sw_count);
    if (st->sw_count) {
        printf("  mean  %6llu ns\n",
               (unsigned long long)(st->sw_sum / st->sw_count));
        printf("  max   %6llu ns\n", (unsigned long long)st->sw_max);
    }

    printf("\nticks published   %u\n", r->published);
    printf("decisions read    %u\n", r->answered);
    printf("unanswered        %u%s\n", r->unanswered,
           r->unanswered ? "  <-- the CPU did not respond in time" : "");
    printf("side mismatches   %u%s\n", r->mismatched,
           r->mismatched ? "  <-- fabric and software disagree" : "");
    printf("CPU rejects       %u   position %d lots   status 0x%X\n",
           s.rejects, s.position, s.status);
    printf("interval          %u us between ticks\n", o->interval_us);

    /*
     * What the two numbers do and do not say.  The fabric figure is a
     * round trip through the bridge including the host's own polling;
     * the software figure is arithmetic only, with no bridge in it.
     * Presenting the second as "what the FPGA beats" would be wrong,
     * and docs/14-latency-and-performance.md says so at more length.
     */
    printf("\nThe fabric figure is a full round trip - publish, CPU loop,\n"
           "decide, poll - across the lightweight bridge.  The software\n"
           "figure is the strategy arithmetic alone, with no bridge in it.\n"
           "They are not competitors; see docs/14-latency-and-performance.md.\n");
}

int main(int argc, char **argv)
{
    struct bench_opts o;
    int rc = parse_args(argc, argv, &o);
    if (rc) return rc < 0 ? 2 : 0;

    fmma_log_init(o.verbose ? FMMA_LOG_DEBUG : FMMA_LOG_INFO);
    signal(SIGINT, on_sigint);

    if (fmma_fabric_check(o.force) != 0) return 1;

    struct fmma_fpga *f = fmma_fpga_open();
    if (!f || !fmma_fpga_present(f)) {
        FMMA_ERROR(TAG, "no FPGA mapping; nothing to measure");
        fmma_fpga_close(f);
        return 1;
    }

    struct fmma_fpga_config cfg;
    memset(&cfg, 0, sizeof(cfg));
    cfg.threshold    = o.threshold;
    cfg.max_position = o.max_position;

    if (o.load) {
        if (fmma_fpga_load(f, &cfg) != 0) {
            fmma_fpga_close(f);
            return 1;
        }
    } else {
        fmma_fpga_push_config(f, &cfg);
    }
    fmma_fpga_set_enabled(f, 1);

    report_loop_rate(f);

    FILE *csv = NULL;
    if (o.csv) {
        csv = fopen(o.csv, "w");
        if (!csv) FMMA_WARN(TAG, "cannot write %s; continuing", o.csv);
        else fprintf(csv, "tick,seq,answer_tick,side,latency_us\n");
    }

    struct fmma_stats st;
    struct fmma_strategy sw;
    fmma_stats_init(&st);
    fmma_strategy_init(&sw, o.threshold, o.max_position, 0);

    FMMA_INFO(TAG, "driving %u synthetic ticks, %u us apart",
              o.ticks, o.interval_us);

    struct run_result r;
    run_ticks(f, &o, &st, &sw, csv, &r);

    if (csv) fclose(csv);

    /* Leave the fabric quiet rather than armed on a series that is not
     * real market data. */
    fmma_fpga_set_enabled(f, 0);

    report(&o, &st, &r, f);
    fmma_fpga_close(f);

    return (r.unanswered || r.mismatched) ? 1 : 0;
}
