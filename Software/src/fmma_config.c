#include "fmma_config.h"
#include "fmma_log.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define TAG "config"

void fmma_config_defaults(struct fmma_config *c)
{
    memset(c, 0, sizeof(*c));
    c->product        = "BTC-USD";
    c->ca_file        = NULL;
    c->symbol         = "BTCUSD";
    c->qty            = "0.001";
    c->cooldown_ms    = 1000;
    c->order_poll_ms  = 500;
    c->threshold      = 1000;      /* $10.00 in cents */
    c->max_position   = 5;
    c->start_position = 0;
    c->half_spread    = 0;
    c->skew           = 0;
    c->max_loss       = 0;         /* disabled until the operator sets it */
    c->stale_feed_ms  = 60000;
    c->poll_ms        = 1;
    c->stats_sec      = 30;
    c->use_fpga       = 1;
    c->dry_run        = 0;
    c->bench          = 0;
    c->force          = 0;
    c->verbose        = 0;
}

void fmma_config_usage(const char *argv0, const struct fmma_config *d)
{
    printf(
"FMMA - Coinbase -> FPGA -> Alpaca\n"
"\n"
"Usage: %s [options]\n"
"\n"
"Mode\n"
"  --no-fpga            run the software reference strategy instead of the\n"
"                       fabric (no /dev/mem, no root needed)\n"
"  --dry-run            never send an order; log what would have been sent\n"
"  --bench              also time the software strategy, for comparison\n"
"  --force              map the bridge even if the FPGA state is unknown\n"
"\n"
"Market data and execution\n"
"  --product ID         Coinbase product id          (default %s)\n"
"  --symbol SYM         broker symbol                (default %s)\n"
"  --qty Q              order size                   (default %s)\n"
"  --cooldown MS        minimum spacing between orders (default %u)\n"
"  --order-poll MS      how often to check a working order (default %u)\n"
"  --ca FILE            CA bundle for TLS            (default: autodetect)\n"
"\n"
"Strategy (pushed to the FPGA, no rebuild needed)\n"
"  --threshold CENTS    move that triggers a decision (default %u = $%.2f)\n"
"  --max-pos N          inventory limit, lots         (default %u)\n"
"  --position N         inventory to start from       (default %d)\n"
"  --half-spread CENTS  quoting strategy half spread  (default %u)\n"
"  --skew CENTS         quoting strategy skew per lot (default %u)\n"
"\n"
"Host-side risk\n"
"  --max-loss CENTS     stop trading past this loss, 0 = off (default %lld)\n"
"  --stale-feed MS      warn if no quote arrives for this long (default %u)\n"
"\n"
"Plumbing\n"
"  --poll-ms MS         event loop tick              (default %u)\n"
"  --stats SEC          statistics interval, 0 = off (default %u)\n"
"  -v, --verbose        raise the log level\n"
"  -h, --help           this text\n"
"\n"
"Credentials come from APCA_API_KEY_ID and APCA_API_SECRET_KEY.\n"
"Use `sudo -E` so they survive; plain sudo strips the environment.\n",
    argv0, d->product, d->symbol, d->qty, d->cooldown_ms, d->order_poll_ms,
    d->threshold, d->threshold / 100.0, d->max_position, d->start_position,
    d->half_spread, d->skew, (long long)d->max_loss, d->stale_feed_ms,
    d->poll_ms, d->stats_sec);
}

/* Small helpers so the parser below stays a flat, readable table. */
static int need_value(int i, int argc, const char *opt)
{
    if (i + 1 >= argc) {
        printf("%s needs a value\n", opt);
        return 0;
    }
    return 1;
}

int fmma_config_parse_args(struct fmma_config *c, int argc, char **argv)
{
    struct fmma_config defaults;
    fmma_config_defaults(&defaults);

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];

        if (!strcmp(a, "-h") || !strcmp(a, "--help")) {
            fmma_config_usage(argv[0], &defaults);
            return 1;
        }
        else if (!strcmp(a, "--no-fpga"))  c->use_fpga = 0;
        else if (!strcmp(a, "--dry-run"))  c->dry_run = 1;
        else if (!strcmp(a, "--bench"))    c->bench = 1;
        else if (!strcmp(a, "--force"))    c->force = 1;
        else if (!strcmp(a, "-v") || !strcmp(a, "--verbose")) c->verbose = 1;

#define STR_OPT(name, field)                                   \
        else if (!strcmp(a, name)) {                           \
            if (!need_value(i, argc, a)) return -1;            \
            c->field = argv[++i];                              \
        }
#define U32_OPT(name, field)                                   \
        else if (!strcmp(a, name)) {                           \
            if (!need_value(i, argc, a)) return -1;            \
            c->field = (uint32_t)strtoul(argv[++i], NULL, 0);  \
        }
#define I32_OPT(name, field)                                   \
        else if (!strcmp(a, name)) {                           \
            if (!need_value(i, argc, a)) return -1;            \
            c->field = (int32_t)strtol(argv[++i], NULL, 0);    \
        }

        STR_OPT("--product",     product)
        STR_OPT("--symbol",      symbol)
        STR_OPT("--qty",         qty)
        STR_OPT("--ca",          ca_file)
        U32_OPT("--cooldown",    cooldown_ms)
        U32_OPT("--order-poll",  order_poll_ms)
        U32_OPT("--threshold",   threshold)
        U32_OPT("--max-pos",     max_position)
        I32_OPT("--position",    start_position)
        U32_OPT("--half-spread", half_spread)
        U32_OPT("--skew",        skew)
        U32_OPT("--stale-feed",  stale_feed_ms)
        U32_OPT("--poll-ms",     poll_ms)
        U32_OPT("--stats",       stats_sec)

        else if (!strcmp(a, "--max-loss")) {
            if (!need_value(i, argc, a)) return -1;
            c->max_loss = (int64_t)strtoll(argv[++i], NULL, 0);
        }
        else {
            printf("unknown option '%s' (try --help)\n", a);
            return -1;
        }

#undef STR_OPT
#undef U32_OPT
#undef I32_OPT
    }

    if (c->poll_ms == 0) c->poll_ms = 1;
    return 0;
}

void fmma_config_dump(const struct fmma_config *c)
{
    FMMA_INFO(TAG, "product %s, symbol %s, qty %s",
              c->product, c->symbol, c->qty);
    FMMA_INFO(TAG, "threshold %u cents, max position %u lots, "
                   "starting position %d",
              c->threshold, c->max_position, c->start_position);
    FMMA_INFO(TAG, "cooldown %u ms, poll %u ms, stats %u s",
              c->cooldown_ms, c->poll_ms, c->stats_sec);
    if (c->max_loss)
        FMMA_INFO(TAG, "loss limit %lld cents", (long long)c->max_loss);
    if (c->dry_run)  FMMA_WARN(TAG, "DRY RUN: no orders will be sent");
    if (!c->use_fpga) FMMA_WARN(TAG, "software-only: the fabric is not used");
}
