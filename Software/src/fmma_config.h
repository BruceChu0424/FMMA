/*
 * FMMA - runtime configuration.
 *
 * Everything tunable lives in one struct with one set of defaults, so
 * "what can I change without rebuilding?" has a single answer.  Nothing
 * here is a compile-time constant except the defaults themselves.
 *
 * Credentials are deliberately NOT in this struct: they come from the
 * environment, are never logged, and never reach a config dump.
 */
#ifndef FMMA_CONFIG_H
#define FMMA_CONFIG_H

#include <stdint.h>

struct fmma_config {
    /* market data */
    const char *product;         /* Coinbase product id, e.g. BTC-USD    */
    const char *ca_file;         /* CA bundle; NULL = autodetect         */

    /* execution */
    const char *symbol;          /* broker symbol, e.g. BTCUSD           */
    const char *qty;             /* order size, as the broker wants it   */
    uint32_t    cooldown_ms;     /* minimum spacing between orders       */
    uint32_t    order_poll_ms;   /* how often to check a working order   */

    /* strategy, pushed to the FPGA */
    uint32_t    threshold;       /* price units (cents)                  */
    uint32_t    max_position;    /* lots                                 */
    int32_t     start_position;  /* lots, signed                         */
    uint32_t    half_spread;     /* quoting strategy, price units        */
    uint32_t    skew;            /* quoting strategy, price units/lot    */

    /* host-side risk */
    int64_t     max_loss;        /* stop trading past this loss, in cents;
                                    0 disables the check                 */
    uint32_t    stale_feed_ms;   /* warn if no quote for this long       */

    /* plumbing */
    uint32_t    poll_ms;         /* event loop tick                      */
    uint32_t    stats_sec;       /* statistics interval, 0 = off         */
    int         use_fpga;        /* 0 = software reference strategy      */
    int         dry_run;         /* 1 = never send an order              */
    int         bench;           /* 1 = time the software strategy too   */
    int         force;           /* skip the fabric-state safety check   */
    int         verbose;         /* raise the log level                  */
};

/* Fill in the defaults. */
void fmma_config_defaults(struct fmma_config *cfg);

/*
 * Apply command-line arguments.  Returns 0 on success, 1 if the program
 * should exit successfully (--help), -1 on a bad argument.
 */
int fmma_config_parse_args(struct fmma_config *cfg, int argc, char **argv);

/* Print the usage text. */
void fmma_config_usage(const char *argv0, const struct fmma_config *defaults);

/* Log the effective configuration (never credentials). */
void fmma_config_dump(const struct fmma_config *cfg);

#endif /* FMMA_CONFIG_H */
