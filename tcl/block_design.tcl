# Block design: wires the three IP blocks together in a PS+PL system.
# Sourced from vivado_project.tcl after create_bd_design.

# Processing System (PS) for PYNQ-Z2
create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_axi_gp0_master_ports "" make_axi_gp0_slave_ports "" apply_board_preset "1"} \
    [get_bd_cells ps7]

# AXI DMA for host ↔ fabric data movement
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 axi_dma_0
set_property CONFIG.c_include_sg {0} [get_bd_cells axi_dma_0]

# HLS feed_parser IP
create_bd_cell -type ip -vlnv com.fpga-crypto:hls:feed_parser:1.0 feed_parser_0

# Chisel OrderBook (instantiated as Verilog module)
create_bd_cell -type module -reference OrderBook orderbook_0
set_property CONFIG.DEPTH  {10} [get_bd_cells orderbook_0]
set_property CONFIG.PRICEBITS {32} [get_bd_cells orderbook_0]
set_property CONFIG.SIZEBITS  {32} [get_bd_cells orderbook_0]

# HLS compute_signals IP
create_bd_cell -type ip -vlnv com.fpga-crypto:hls:compute_signals:1.0 signals_0

# AXI interconnect for PS → DMA → parser
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_ic
set_property CONFIG.NUM_SI {1} [get_bd_cells axi_ic]
set_property CONFIG.NUM_MI {1} [get_bd_cells axi_ic]

# Clock/reset from PS
connect_bd_net [get_bd_pins ps7/FCLK_CLK0]     [get_bd_pins feed_parser_0/ap_clk]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0]     [get_bd_pins orderbook_0/clock]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0]     [get_bd_pins signals_0/ap_clk]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0]     [get_bd_pins axi_dma_0/s_axi_lite_aclk]
connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N] [get_bd_pins feed_parser_0/ap_rst_n]
connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N] [get_bd_pins orderbook_0/reset]
connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N] [get_bd_pins signals_0/ap_rst_n]

# Data path: DMA MM2S → parser in_bytes
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXIS_MM2S] \
                    [get_bd_intf_pins feed_parser_0/in_bytes]

# Parser out_msgs → OrderBook AXI-Stream slave
connect_bd_intf_net [get_bd_intf_pins feed_parser_0/out_msgs] \
                    [get_bd_intf_pins orderbook_0/s_axis]

# OrderBook snapshot → signals engine (via AXI-Lite or direct wire — simplified here)
# In a real design you'd use an AXI4-Stream FIFO between them
connect_bd_intf_net [get_bd_intf_pins orderbook_0/snap_axis] \
                    [get_bd_intf_pins signals_0/in_snap]

# Signals out → DMA S2MM (back to PS)
connect_bd_intf_net [get_bd_intf_pins signals_0/out_sig] \
                    [get_bd_intf_pins axi_dma_0/S_AXIS_S2MM]

puts "Block design wired."
