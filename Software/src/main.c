/*
 * FMMA - FPGA Market Maker Accelerator
 *
 * Coinbase quotes in, a trading decision made in FPGA fabric, a paper
 * order out.  This file does nothing but start and stop; the shape of
 * the system is in fmma_app.c and the contract with the fabric is in
 * docs/07-shared-memory-protocol.md.
 *
 * Exit codes, so a script can tell what went wrong:
 *   0  clean shutdown
 *   1  bad arguments
 *   2  the FPGA is not configured, or not safe to touch
 *   3  the CPU in the fabric did not start
 */

#include "fmma_app.h"
#include "fmma_config.h"
#include "fmma_log.h"

#include "../fmma_protocol.h"

#include <signal.h>
#include <stdio.h>

static void on_signal(int sig)
{
    (void)sig;
    fmma_app_stop();
}

int main(int argc, char **argv)
{
    struct fmma_config cfg;
    fmma_config_defaults(&cfg);

    int rc = fmma_config_parse_args(&cfg, argc, argv);
    if (rc > 0) return 0;        /* --help */
    if (rc < 0) return 1;

    fmma_log_init(cfg.verbose ? FMMA_LOG_DEBUG : FMMA_LOG_INFO);

    fmma_print("=== FMMA: %s -> %s -> paper trading (protocol v%u) ===\n",
               cfg.product,
               cfg.use_fpga ? "FPGA" : "software", FMMA_PROTOCOL_VERSION);
    fmma_config_dump(&cfg);

    signal(SIGINT,  on_signal);
    signal(SIGTERM, on_signal);
    signal(SIGPIPE, SIG_IGN);    /* a dropped socket must not kill us */

    struct fmma_app *app = fmma_app_create(&cfg);
    if (app == NULL) return cfg.use_fpga ? 2 : 3;

    int result = fmma_app_run(app);
    fmma_app_destroy(app);
    return result;
}
