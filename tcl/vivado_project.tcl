# Vivado project creation and synthesis script (Tier 2/3)
# Builds a block design wiring: feed_parser IP → OrderBook Verilog → compute_signals IP
# Usage: vivado -mode batch -source tcl/vivado_project.tcl

set project_name "fpga_crypto_feed"
set part         "xc7z020clg400-1"
set board        "tul.com.tw:pynq-z2:part0:1.0"   ;# PYNQ-Z2

# Path to generated IPs
set hls_parser_ip  "[pwd]/feed_parser/solution1/impl/ip"
set hls_signals_ip "[pwd]/compute_signals/solution1/impl/ip"
set chisel_verilog  "[pwd]/chisel/generated/OrderBook.v"

# ---------------------------------------------------------------
create_project $project_name ./vivado/$project_name -part $part -force
set_property board_part $board [current_project]

# Add HLS IPs to catalog
set_property ip_repo_paths [list $hls_parser_ip $hls_signals_ip] [current_project]
update_ip_catalog -rebuild

# Add Chisel-generated Verilog
add_files -norecurse $chisel_verilog
update_compile_order -fileset sources_1

# Add constraints (for PYNQ-Z2)
add_files -fileset constrs_1 -norecurse constraints/pynq_z2.xdc

# Create block design
create_bd_design "feed_handler_bd"
source tcl/block_design.tcl

# Validate, generate wrapper, synthesize
validate_bd_design
make_wrapper -files [get_files feed_handler_bd.bd] -top
add_files -norecurse ./vivado/$project_name/$project_name.srcs/sources_1/bd/feed_handler_bd/hdl/feed_handler_bd_wrapper.v

# Run synthesis and implementation
launch_runs synth_1 -jobs 8
wait_on_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

# Report timing and resources
open_run impl_1
report_timing_summary -file ./vivado/timing_summary.rpt
report_utilization    -file ./vivado/utilization.rpt

puts "=== Vivado implementation complete — check vivado/timing_summary.rpt ==="
