# Vivado batch flow (Tier 2): project -> block design -> synthesis -> implementation
# -> bitstream + hardware handoff for PYNQ, plus post-route timing/utilization.
#
#   vivado -mode batch -source tcl/vivado_project.tcl                       (from repo root)
#   vivado -mode batch -source tcl/vivado_project.tcl -tclargs clk:100      (other FCLK_CLK0, MHz)
#   make synth / make vm-bitstream
#
# Prerequisites: tcl/run_hls_parser.tcl and tcl/run_hls_signals.tcl have exported
# feed_parser/solution1/impl/ip and compute_signals/solution1/impl/ip, and
# `make chisel-verilog` has written chisel/generated/OrderBook.v.
#
# Outputs
#   reports/impl/timing_summary.rpt, utilization.rpt      (committed)
#   build/feed_handler_bd_wrapper.bit, feed_handler_bd.hwh (gitignored; copy both to the board)
#
# Tested target: PYNQ-Z2 (xc7z020clg400-1). The TUL board files are optional:
# without them the PS7 is configured from PCW defaults (a warning is printed).

set root      [file normalize [file join [file dirname [info script]] ..]]
set proj_name "fpga_crypto_feed"
set proj_dir  "$root/vivado/$proj_name"
set part      "xc7z020clg400-1"
set board     "tul.com.tw:pynq-z2:part0:1.0"
set bd_name   "feed_handler_bd"
set rpt_dir   "$root/reports/impl"
set out_dir   "$root/build"

set FEED_CLK_MHZ 250
if {[string match "clk:*" [lindex $argv 0]]} { set FEED_CLK_MHZ [string range [lindex $argv 0] 4 end] }
if {$FEED_CLK_MHZ != 250} { set rpt_dir "$root/reports/impl_${FEED_CLK_MHZ}MHz" }

file mkdir $rpt_dir
file mkdir $out_dir

create_project $proj_name $proj_dir -part $part -force
if {[catch {set_property board_part $board [current_project]} msg]} {
    puts "WARNING: PYNQ-Z2 board files not found ($msg); continuing with bare part $part"
}

set_property ip_repo_paths [list "$root/feed_parser/solution1/impl/ip" "$root/compute_signals/solution1/impl/ip"] [current_project]
update_ip_catalog -rebuild

add_files -norecurse [list "$root/chisel/generated/OrderBook.v" "$root/rtl/orderbook_axis_wrap.v"]
add_files -fileset constrs_1 -norecurse "$root/constraints/pynq_z2.xdc"
update_compile_order -fileset sources_1

create_bd_design $bd_name
source "$root/tcl/block_design.tcl"
validate_bd_design
save_bd_design

make_wrapper -files [get_files $bd_name.bd] -top
add_files -norecurse [glob $proj_dir/$proj_name.gen/sources_1/bd/$bd_name/hdl/${bd_name}_wrapper.v]
set_property top ${bd_name}_wrapper [current_fileset]
update_compile_order -fileset sources_1

launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} { error "synthesis failed" }

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} { error "implementation failed" }

open_run impl_1
report_timing_summary -file "$rpt_dir/timing_summary.rpt"
report_utilization -file "$rpt_dir/utilization.rpt"
report_utilization -hierarchical -file "$rpt_dir/utilization_hierarchical.rpt"
report_timing -setup -max_paths 10 -nworst 1 -file "$rpt_dir/setup_paths.rpt"
report_clock_utilization -file "$rpt_dir/clock_utilization.rpt"
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
puts "Post-route at $FEED_CLK_MHZ MHz: WNS=$wns ns WHS=$whs ns"

file copy -force "$proj_dir/$proj_name.runs/impl_1/${bd_name}_wrapper.bit" "$out_dir/${bd_name}_wrapper.bit"
file copy -force [glob $proj_dir/$proj_name.gen/sources_1/bd/$bd_name/hw_handoff/$bd_name.hwh] "$out_dir/$bd_name.hwh"
puts "=== Vivado implementation complete: $rpt_dir/timing_summary.rpt, $out_dir/${bd_name}_wrapper.bit ==="
