# Vitis HLS script: C-sim + synthesis + cosim for the compute_signals IP
# Usage: vitis_hls -f tcl/run_hls_signals.tcl

set project_name "compute_signals"
set top_function "compute_signals"
set part "xc7z020clg400-1"
set period_ns 4

open_project -reset $project_name
set_top $top_function

add_files hls/signals/signals.cpp
add_files hls/signals/signals.h
add_files -tb hls/signals/signals_tb.cpp

open_solution "solution1" -flow_target vivado
set_part $part
create_clock -period $period_ns -name default

csim_design -clean
csynth_design
cosim_design -O -rtl verilog
export_design -format ip_catalog -description "Signal Engine" -version "1.0"

close_project
puts "=== compute_signals HLS flow complete ==="
