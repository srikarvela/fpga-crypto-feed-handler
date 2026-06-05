# Vitis HLS script: C-sim + synthesis + cosim for the feed_parser IP
# Usage: vitis_hls -f tcl/run_hls_parser.tcl

set project_name "feed_parser"
set top_function "feed_parser"
set part "xc7z020clg400-1"   ;# Zynq-7020 (PYNQ-Z2 / Arty Z7 compatible)
set period_ns 4               ;# 250 MHz target

# ---------------------------------------------------------------
open_project -reset $project_name
set_top $top_function

add_files hls/parser/parser.cpp  -cflags "-DTICK_SIZE=100"
add_files hls/parser/msg_types.h -cflags "-DTICK_SIZE=100"
add_files -tb hls/parser/parser_tb.cpp

open_solution "solution1" -flow_target vivado
set_part $part
create_clock -period $period_ns -name default

# C Simulation
csim_design -clean

# HLS Synthesis
csynth_design

# Co-simulation (RTL verify with the same testbench)
cosim_design -O -rtl verilog

# Export as Vivado IP (for Tier 2/3 block design)
export_design -format ip_catalog -description "Crypto Feed Parser" -version "1.0"

close_project
puts "=== feed_parser HLS flow complete ==="
