# Master script: runs both HLS flows, generates Chisel Verilog, then Vivado.
# Usage: tclsh tcl/run_all.tcl   (or source from Vivado Tcl console)

proc run_hls {script} {
    set rc [catch {exec vitis_hls -f $script} out]
    puts $out
    if {$rc != 0} { error "HLS failed on $script" }
}

proc run_chisel {} {
    set rc [catch {exec sbt --batch "runMain orderbook.OrderBookVerilog" \
                  2>@1} out]
    puts $out
    if {$rc != 0} { error "Chisel Verilog generation failed" }
}

puts "=== Step 1: HLS parser ==="
run_hls tcl/run_hls_parser.tcl

puts "=== Step 2: HLS signals ==="
run_hls tcl/run_hls_signals.tcl

puts "=== Step 3: Chisel → Verilog ==="
run_chisel

puts "=== Step 4: Vivado synthesis + implementation ==="
exec vivado -mode batch -source tcl/vivado_project.tcl 2>@1

puts "=== ALL DONE ==="
