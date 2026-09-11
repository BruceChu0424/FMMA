/*
 * FMMA - protocol conformance, checked on real hardware.
 *
 * The RTL testbenches assert these same properties against the
 * simulated design, and the instruction-set simulator checks them
 * against the golden model.  Neither runs on the board, and the board
 * is where the interesting failures live: a bitstream that is not the
 * one you think it is, a program image that did not fully land, an
 * on-chip RAM configured with the wrong read-during-write behaviour.
 *
 * So this runs the same properties past the real fabric, over the real
 * bridge, and says which ones hold.  It is the hardware half of
 * docs/12-verification-plan.md.
 *
 * Each check drives the protocol exactly as the application does -
 * through fmma_fpga.c, not through its own copy of the rules - so a
 * pass says something about the shipping code path.
 */
#ifndef FMMA_SELFTEST_H
#define FMMA_SELFTEST_H

struct fmma_fpga;

struct fmma_selftest_result {
    unsigned run;
    unsigned passed;
    unsigned failed;
};

/*
 * Run every check against a CPU that is already loaded and running.
 * Leaves trading disabled and the configuration at defaults.
 *
 * Returns 0 when everything passed.
 */
int fmma_selftest_run(struct fmma_fpga *f, struct fmma_selftest_result *out);

#endif /* FMMA_SELFTEST_H */
