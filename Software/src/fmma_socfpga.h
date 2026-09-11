/*
 * FMMA - "is it safe to touch the bridge?"
 *
 * This exists because of a specific and nasty failure mode.
 *
 * On Cyclone V there is no timeout on the HPS-to-FPGA bridge.  If the
 * fabric is not configured, or is configured with a design that has no
 * slave at the address being accessed, the AXI transaction never
 * completes and the CPU that issued it blocks forever.  That is not a
 * segfault you can catch - it takes the core down, and in practice the
 * whole board, hard enough to need a power cycle.
 *
 * A single read of an unconfigured bridge did exactly that during
 * bring-up.  So nothing in this project maps the bridge without first
 * asking the FPGA manager whether the fabric is actually configured.
 *
 * The check is not perfect: the fabric can be in user mode with a design
 * that has nothing at 0xFF200000, and no software can detect that
 * without performing the access that hangs.  What the check does remove
 * is the common case - a failed or absent configuration - and it makes
 * the residual risk explicit rather than a surprise.  For a first
 * bring-up of a new bitstream, confirm visually on HEX0 first; see
 * docs/11-board-bringup.md.
 */
#ifndef FMMA_SOCFPGA_H
#define FMMA_SOCFPGA_H

enum fmma_fabric_state {
    FMMA_FABRIC_USER_MODE,     /* configured and running               */
    FMMA_FABRIC_UNCONFIGURED,  /* powered up, reset, or config failed  */
    FMMA_FABRIC_UNKNOWN        /* no FPGA manager: not a SoC FPGA, or
                                  a kernel without the driver          */
};

/* Read /sys/class/fpga/fpga0/status (or the newer fpga_manager path). */
enum fmma_fabric_state fmma_fabric_state(void);

/* Human-readable form of whatever the FPGA manager reported. */
const char *fmma_fabric_state_text(void);

/*
 * Returns 0 when it is safe to map the bridge.  Otherwise logs why and
 * returns -1.  `force` skips the check for the case where the state
 * cannot be determined and the caller knows better.
 */
int fmma_fabric_check(int force);

#endif /* FMMA_SOCFPGA_H */
