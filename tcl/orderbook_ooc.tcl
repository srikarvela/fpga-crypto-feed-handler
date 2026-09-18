# Out-of-context synthesis + place & route of the Chisel OrderBook alone at the
# 250 MHz pipeline constraint, so its timing can be read separately from the
# PS7/DMA system in vivado_project.tcl. Same non-project flow as the sibling
# cordic-engine / kalman-filter repos.
#
#   vivado -mode batch -source tcl/orderbook_ooc.tcl                      (4.000 ns)
#   vivado -mode batch -source tcl/orderbook_ooc.tcl -tclargs period:8.000
#
# Outputs: reports/ooc/N_<period>ns/{timing_summary,utilization}.rpt (committed)

set part "xc7z020clg400-1"
set period 4.000
if {[string match "period:*" [lindex $argv 0]]} { set period [string range [lindex $argv 0] 7 end] }

set root [file normalize [file join [file dirname [info script]] ..]]
set out  [file join $root reports ooc [format "N_%.3fns" $period]]
file mkdir $out

create_project -in_memory -part $part
read_verilog [file join $root chisel generated OrderBook.v]
synth_design -top OrderBook -part $part -mode out_of_context
create_clock -name clock -period $period [get_ports clock]
set_input_delay  -clock clock 0.500 [all_inputs]
set_output_delay -clock clock 0.500 [all_outputs]
opt_design
place_design
phys_opt_design
route_design
report_timing_summary -file [file join $out timing_summary.rpt]
report_utilization    -file [file join $out utilization.rpt]
report_timing -setup -max_paths 5 -nworst 1 -file [file join $out setup_paths.rpt]
set wns [get_property SLACK [get_timing_paths -max_paths 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -hold]]
puts [format "=== OrderBook OOC period=%.3f: WNS=%s WHS=%s Fmax=%.1fMHz ===" $period $wns $whs [expr {1000.0 / ($period - $wns)}]]
close_project
