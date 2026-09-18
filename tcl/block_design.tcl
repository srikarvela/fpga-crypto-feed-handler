# Block design: Zynq PS <-- AXI DMA --> feed_parser -> OrderBook -> compute_signals --> AXI DMA --> PS
# Sourced from vivado_project.tcl after create_bd_design. Same PS7/DMA skeleton as
# the sibling neuromorphic-logic-controller repo's fpga/tcl/bd_nlc.tcl.
#
#   ps7.M_AXI_GP0 --> axi_dma_0.S_AXI_LITE                   (DMA control registers)
#   axi_dma_0.M_AXI_MM2S / M_AXI_S2MM --> ps7.S_AXI_HP0      (DDR access)
#   axi_dma_0.M_AXIS_MM2S (8-bit) --> feed_parser_0.in_bytes  (22-byte raw messages, one byte per beat)
#   feed_parser_0.out_msgs (128-bit) --> orderbook_0.s_axis   (packed NormMsg)
#   orderbook_0.m_axis (BookSnap) --> signals_0.in_snap
#   signals_0.out_sig --> axis_dwidth_converter_0 --> axi_dma_0.S_AXIS_S2MM (8-bit)
#
# Everything runs on FCLK_CLK0 at the pipeline's 250 MHz target (FEED_CLK_MHZ).

set bd_name [current_bd_design]
if {![info exists FEED_CLK_MHZ]} { set FEED_CLK_MHZ 250 }

# --- Processing system: PYNQ-Z2 preset if the board files are installed
#     (otherwise PCW defaults), one fabric clock, GP0 master + HP0 slave for the DMA
create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR" apply_board_preset "1" Master "Disable" Slave "Disable"} \
    [get_bd_cells ps7]
set_property -dict [list \
    CONFIG.PCW_USE_M_AXI_GP0 {1} \
    CONFIG.PCW_USE_S_AXI_HP0 {1} \
    CONFIG.PCW_S_AXI_HP0_DATA_WIDTH {64} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ $FEED_CLK_MHZ \
    CONFIG.PCW_EN_CLK0_PORT {1} \
    CONFIG.PCW_EN_RST0_PORT {1} \
] [get_bd_cells ps7]

# --- AXI DMA, simple (non-scatter-gather) mode. The parser consumes one byte
#     per beat and the signal record is 25 bytes, so both streams are 8 bits wide.
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 axi_dma_0
set_property -dict [list \
    CONFIG.c_include_sg {0} \
    CONFIG.c_sg_include_stscntrl_strm {0} \
    CONFIG.c_include_mm2s {1} \
    CONFIG.c_include_s2mm {1} \
    CONFIG.c_m_axis_mm2s_tdata_width {8} \
    CONFIG.c_s_axis_s2mm_tdata_width {8} \
    CONFIG.c_m_axi_mm2s_data_width {32} \
    CONFIG.c_m_axi_s2mm_data_width {32} \
    CONFIG.c_mm2s_burst_size {16} \
    CONFIG.c_s2mm_burst_size {16} \
    CONFIG.c_sg_length_width {23} \
] [get_bd_cells axi_dma_0]

# --- HLS IPs (exported by tcl/run_hls_*.tcl; VLNV looked up so the vendor string
#     does not have to be hard-coded)
proc hls_vlnv {name} {
    set defs [get_ipdefs -all -filter "NAME == $name"]
    if {[llength $defs] == 0} { error "HLS IP '$name' not in the catalog: run the HLS flows first" }
    return [get_property VLNV [lindex $defs 0]]
}
create_bd_cell -type ip -vlnv [hls_vlnv feed_parser]     feed_parser_0
create_bd_cell -type ip -vlnv [hls_vlnv compute_signals] signals_0

# --- Chisel OrderBook via rtl/orderbook_axis_wrap.v (module reference: exposes
#     s_axis / m_axis AXI4-Stream interfaces around the generated OrderBook.v)
create_bd_cell -type module -reference orderbook_axis_wrap orderbook_0

# --- Signal record (25 bytes) -> 8-bit stream for the DMA
set sig_bytes [get_property CONFIG.TDATA_NUM_BYTES [get_bd_intf_pins signals_0/out_sig]]
create_bd_cell -type ip -vlnv xilinx.com:ip:axis_dwidth_converter:1.1 axis_dwidth_converter_0
set_property -dict [list \
    CONFIG.S_TDATA_NUM_BYTES $sig_bytes \
    CONFIG.M_TDATA_NUM_BYTES {1} \
    CONFIG.HAS_TLAST {0} \
    CONFIG.HAS_TKEEP {0} \
    CONFIG.HAS_TSTRB {0} \
] [get_bd_cells axis_dwidth_converter_0]

# --- Streams
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXIS_MM2S]   [get_bd_intf_pins feed_parser_0/in_bytes]
connect_bd_intf_net [get_bd_intf_pins feed_parser_0/out_msgs]  [get_bd_intf_pins orderbook_0/s_axis]
connect_bd_intf_net [get_bd_intf_pins orderbook_0/m_axis]      [get_bd_intf_pins signals_0/in_snap]
connect_bd_intf_net [get_bd_intf_pins signals_0/out_sig]       [get_bd_intf_pins axis_dwidth_converter_0/S_AXIS]
connect_bd_intf_net [get_bd_intf_pins axis_dwidth_converter_0/M_AXIS] [get_bd_intf_pins axi_dma_0/S_AXIS_S2MM]

# --- Memory-mapped side: the automation adds the interconnects and the
#     processor system reset block, all on FCLK_CLK0
set clk "/ps7/FCLK_CLK0 ($FEED_CLK_MHZ MHz)"
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config [list Clk_master $clk Clk_slave {Auto} Clk_xbar {Auto} \
             Master {/ps7/M_AXI_GP0} Slave {/axi_dma_0/S_AXI_LITE} intc_ip {New AXI Interconnect} master_apm {0}] \
    [get_bd_intf_pins axi_dma_0/S_AXI_LITE]
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config [list Clk_master {Auto} Clk_slave $clk Clk_xbar {Auto} \
             Master {/axi_dma_0/M_AXI_MM2S} Slave {/ps7/S_AXI_HP0} intc_ip {New AXI Interconnect} master_apm {0}] \
    [get_bd_intf_pins ps7/S_AXI_HP0]
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config [list Clk_master {Auto} Clk_slave $clk Clk_xbar {Auto} \
             Master {/axi_dma_0/M_AXI_S2MM} Slave {/ps7/S_AXI_HP0} intc_ip {/axi_mem_intercon} master_apm {0}] \
    [get_bd_intf_pins axi_dma_0/M_AXI_S2MM]

# --- Clock and reset for the pipeline
set psr [get_bd_cells -hierarchical -filter {VLNV =~ "xilinx.com:ip:proc_sys_reset:*"}]
if {[llength $psr] == 0} { error "no proc_sys_reset block was created by the automation" }
set arstn [get_bd_pins [lindex $psr 0]/peripheral_aresetn]
foreach c {feed_parser_0/ap_clk orderbook_0/aclk signals_0/ap_clk axis_dwidth_converter_0/aclk} {
    connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins $c]
}
foreach r {feed_parser_0/ap_rst_n orderbook_0/aresetn signals_0/ap_rst_n axis_dwidth_converter_0/aresetn} {
    connect_bd_net $arstn [get_bd_pins $r]
}

assign_bd_address
regenerate_bd_layout
puts "Block design $bd_name wired: ps7 <-> axi_dma_0 <-> feed_parser_0 -> orderbook_0 -> signals_0 -> dwidth -> axi_dma_0 @ $FEED_CLK_MHZ MHz"
