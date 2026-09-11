# ------------------------------------------------------------------ #
# FMMA - FPGA Market Maker Accelerator
# HFTTop.sdc - timing constraints
#
# There is one clock in the fabric: the 50 MHz board oscillator.
# Everything the CPU owns (PC, IR, FR, register bank, control FSM)
# clocks on its FALLING edge, and the shared on-chip RAM inside the
# Qsys system clocks on the RISING edge.  The Timing Analyzer derives
# the launch and latch edges from each register's clock sense, so a
# single create_clock is enough to constrain the half-period
# CPU -> RAM and RAM -> CPU paths correctly; no multicycle or
# false-path exception is wanted on them.
#
# The HPS SDRAM interface brings its own constraints in through the
# .qip (hps_sdram_p0.sdc), and the HPS-to-FPGA bridge runs on this
# same 50 MHz clock, so there is no clock-domain crossing anywhere in
# the design.
# ------------------------------------------------------------------ #

create_clock -period 20.000 -name clk50 [get_ports {CLOCK_50}]

derive_clock_uncertainty

# ------------------------------------------------------------------ #
# HEX0 is the debug display: the low nibble of the program counter,
# driven straight out of the fabric to a seven-segment digit.  There
# is no receiving clock and no setup/hold requirement - the only
# consumer is a person looking at the board - so cut it rather than
# leaving 28 output paths unconstrained and silently excluded from
# sign-off.
# ------------------------------------------------------------------ #

set_false_path -to [get_ports {HEX0[*]}]

# ------------------------------------------------------------------ #
# KEY[0] is the CPU reset button: a mechanical contact with no timing
# relationship to CLOCK_50.  The top level runs it through two
# synchroniser flops, so the only thing to tell the analyser is that
# the pad-to-first-flop path is not a timed path.
# ------------------------------------------------------------------ #

set_false_path -from [get_ports {KEY[0]}]

# CLOCK_50 is the only other input port and it is the clock itself, so
# there are no input delays to declare.  The HPS DDR3 pins belong to
# the HPS hard IP and are constrained by its generated .sdc.
