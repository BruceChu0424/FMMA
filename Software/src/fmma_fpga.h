/*
 * FMMA - the host half of the shared-memory protocol.
 *
 * Everything that touches the FPGA goes through here, so the protocol
 * rules in docs/07-shared-memory-protocol.md are implemented in exactly
 * one place:
 *
 *   - market data is published under a seqlock (odd while writing)
 *   - fills are published last-field-last
 *   - decisions are read by edge-detecting a counter the host never writes
 *   - the host writes only the input block, the CPU only the output block
 *
 * With --no-fpga none of this is available; every function tolerates a
 * closed device so the caller does not need a null check at each site.
 */
#ifndef FMMA_FPGA_H
#define FMMA_FPGA_H

#include <stdint.h>

/* Physical base of the lightweight HPS-to-FPGA bridge on Cyclone V. */
#define FMMA_LW_H2F_BASE  0xFF200000UL

struct fmma_fpga;

/* A decision read out of the fabric. */
struct fmma_signal {
    uint32_t side;        /* FMMA_SIGNAL_BUY or FMMA_SIGNAL_SELL */
    uint32_t tick;        /* the TICK_SEQ it was computed from   */
    uint32_t seq;         /* its SIGNAL_SEQ                      */
    uint32_t missed;      /* decisions skipped since the last poll */
};

/* -- lifecycle ---------------------------------------------------------- */

/* Map the bridge. Returns NULL and logs why on failure. */
struct fmma_fpga *fmma_fpga_open(void);
void fmma_fpga_close(struct fmma_fpga *f);

/* True when a real mapping exists (false in software-only mode). */
int fmma_fpga_present(const struct fmma_fpga *f);

/* -- bringing the CPU up ------------------------------------------------ */

struct fmma_fpga_config {
    uint32_t threshold;      /* CFG_THRESH, price units        */
    uint32_t max_position;   /* CFG_MAX_POS, lots              */
    int32_t  start_position; /* CFG_POSITION, lots, signed     */
    uint32_t half_spread;    /* CFG_HALF_SPREAD, price units   */
    uint32_t skew;           /* CFG_SKEW, price units per lot  */
};

/*
 * Write the program image and the configuration, then restart the CPU and
 * wait for it to declare the protocol version.
 *
 * The image is written with the entry word LAST: until that store lands
 * the word the PC sits on is still zero, which is the CPU's halt
 * instruction, so a partially written program cannot start.
 *
 * Returns 0 on success; -1 with an explanation logged otherwise.
 */
int fmma_fpga_load(struct fmma_fpga *f, const struct fmma_fpga_config *cfg);

/* Enable or suppress trading without stopping the engine. */
void fmma_fpga_set_enabled(struct fmma_fpga *f, int enabled);

/* Push configuration to a CPU that is already running. */
void fmma_fpga_push_config(struct fmma_fpga *f,
                           const struct fmma_fpga_config *cfg);

/* -- the runtime protocol ----------------------------------------------- */

/* Publish one market-data snapshot through the seqlock.
 * Returns the tick sequence number the CPU will see. */
uint32_t fmma_fpga_publish_tick(struct fmma_fpga *f,
                                uint32_t bid, uint32_t ask,
                                uint32_t bid_size, uint32_t ask_size);

/* Report a fill so the CPU's inventory tracks the broker's. */
void fmma_fpga_report_fill(struct fmma_fpga *f, uint32_t side, uint32_t qty);

/*
 * Poll for a new decision.  Returns 1 and fills `out` when the CPU has
 * published one, 0 otherwise.  Never writes to the output block.
 */
int fmma_fpga_poll_signal(struct fmma_fpga *f, struct fmma_signal *out);

/* -- observation -------------------------------------------------------- */

struct fmma_fpga_state {
    uint32_t heartbeat;
    int32_t  position;
    uint32_t status;
    uint32_t rejects;
    uint32_t version;
    uint32_t quote_bid;
    uint32_t quote_ask;
};

void fmma_fpga_read_state(struct fmma_fpga *f, struct fmma_fpga_state *out);

/* Raw access, for diagnostics and tests only. */
uint32_t fmma_fpga_read(struct fmma_fpga *f, unsigned word);
void     fmma_fpga_write(struct fmma_fpga *f, unsigned word, uint32_t value);

/* Loops the CPU has completed since the last call - a liveness check that
 * also gives the observed loop rate. */
uint32_t fmma_fpga_heartbeat_delta(struct fmma_fpga *f);

#endif /* FMMA_FPGA_H */
