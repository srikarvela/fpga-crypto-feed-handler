# PYNQ-Z2 constraints
# 125 MHz PS clock (FCLK_CLK0 configured via PS7 in block design)
# Add any custom pin assignments for PMOD/GPIO debug here.

# System clock from PS — no external oscillator needed for this design
# (all clocks sourced from PS7 PLL, configured in block_design.tcl)

# Uncomment for ILA / ChipScope debug on PMOD JA header
# set_property PACKAGE_PIN Y18 [get_ports {debug[0]}]
# set_property IOSTANDARD LVCMOS33 [get_ports {debug[0]}]
