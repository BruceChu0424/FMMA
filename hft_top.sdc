# Timing constraints for hft_top (the HPS's own SDC files come in via HPSfgpa2.qip)
create_clock -name CLOCK_50 -period 20.000 [get_ports CLOCK_50]
derive_clock_uncertainty

# Pushbutton and LEDs are asynchronous to the design
set_false_path -from [get_ports {KEY[*]}]
set_false_path -to   [get_ports {LEDR[*]}]
