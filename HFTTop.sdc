# ------------------------------------------------------------------ #
# FMMA - FPGA Market Maker Accelerator
# HFTTop.sdc - timing constraints
#
# The whole CPU runs on the falling edge of the 50 MHz clock and
# the shared RAM (inside the Qsys system) on the rising edge, so
# CPU register -> RAM and RAM -> CPU paths get half a period
# (10 ns). The Qsys-generated HPS SDRAM constraints come in via
# the .qip file.
# ------------------------------------------------------------------ #

create_clock -period 20.000 -name clk50 [get_ports {CLOCK_50}]

# The HPS DDR3 hard-interface conduit is owned by the HPS IP and
# handled by its generated constraints; nothing extra to do here.
