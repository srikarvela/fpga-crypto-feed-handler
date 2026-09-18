// Plain Verilog-2001 shell around the Chisel-generated OrderBook for Vivado IP
// Integrator (create_bd_cell -type module -reference orderbook_axis_wrap).
// Same pattern as the sibling neuromorphic-logic-controller repo's rtl/nlc_axis_top_wrap.v.
//
// s_axis: the HLS feed_parser's out_msgs (128-bit AXI4-Stream carrying one packed
//         NormMsg: {seq_num[96:65], side[64], size[63:32], price[31:0]}; bits 127:97 pad).
// m_axis: the BookSnapshot as the HLS compute_signals IP's in_snap expects it. Vitis
//         HLS lays hls::stream<BookSnap> out with C struct alignment (2016-bit TDATA):
//           bids[i]: price @ 96*i, size @ 96*i+32, valid @ 96*i+64 (31 pad bits)   i = 0..9
//           asks[i]: the same at 960 + 96*i
//           imbalance @ 1920, midprice @ 1952, seq_num @ 1984
//         (offsets read from compute_signals/solution1/impl/verilog/compute_signals.v).
//
// The snapshot is a registered one-cycle pulse (io_snap_valid) with no backpressure
// in the Chisel design, so m_axis_tready is not consumed: if the downstream IP
// stalls, that snapshot is dropped. No TLAST on either stream (the HLS IPs have none).
`default_nettype none
module orderbook_axis_wrap #(
    parameter DEPTH     = 10,
    parameter PRICEBITS = 32,
    parameter SIZEBITS  = 32
) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axis:m_axis, ASSOCIATED_RESET aresetn" *)
    input  wire          aclk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire          aresetn,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TDATA" *)
    input  wire [127:0]  s_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TVALID" *)
    input  wire          s_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TREADY" *)
    output wire          s_axis_tready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TDATA" *)
    output wire [2015:0] m_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TVALID" *)
    output wire          m_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TREADY" *)
    input  wire          m_axis_tready
);

  // Chisel reset is synchronous, active-high
  reg reset_r;
  always @(posedge aclk) reset_r <= ~aresetn;

  wire [31:0] bid_price [0:9];
  wire [31:0] bid_size  [0:9];
  wire        bid_valid [0:9];
  wire [31:0] ask_price [0:9];
  wire [31:0] ask_size  [0:9];
  wire        ask_valid [0:9];
  wire [31:0] imbalance, midprice, seq_num;
  wire        snap_valid;

  OrderBook u_book (
      .clock(aclk),
      .reset(reset_r),
      .io_s_axis_tdata(s_axis_tdata[96:0]),
      .io_s_axis_tvalid(s_axis_tvalid),
      .io_s_axis_tready(s_axis_tready),
      .io_snap_bids_0_price(bid_price[0]), .io_snap_bids_0_size(bid_size[0]), .io_snap_bids_0_valid(bid_valid[0]),
      .io_snap_bids_1_price(bid_price[1]), .io_snap_bids_1_size(bid_size[1]), .io_snap_bids_1_valid(bid_valid[1]),
      .io_snap_bids_2_price(bid_price[2]), .io_snap_bids_2_size(bid_size[2]), .io_snap_bids_2_valid(bid_valid[2]),
      .io_snap_bids_3_price(bid_price[3]), .io_snap_bids_3_size(bid_size[3]), .io_snap_bids_3_valid(bid_valid[3]),
      .io_snap_bids_4_price(bid_price[4]), .io_snap_bids_4_size(bid_size[4]), .io_snap_bids_4_valid(bid_valid[4]),
      .io_snap_bids_5_price(bid_price[5]), .io_snap_bids_5_size(bid_size[5]), .io_snap_bids_5_valid(bid_valid[5]),
      .io_snap_bids_6_price(bid_price[6]), .io_snap_bids_6_size(bid_size[6]), .io_snap_bids_6_valid(bid_valid[6]),
      .io_snap_bids_7_price(bid_price[7]), .io_snap_bids_7_size(bid_size[7]), .io_snap_bids_7_valid(bid_valid[7]),
      .io_snap_bids_8_price(bid_price[8]), .io_snap_bids_8_size(bid_size[8]), .io_snap_bids_8_valid(bid_valid[8]),
      .io_snap_bids_9_price(bid_price[9]), .io_snap_bids_9_size(bid_size[9]), .io_snap_bids_9_valid(bid_valid[9]),
      .io_snap_asks_0_price(ask_price[0]), .io_snap_asks_0_size(ask_size[0]), .io_snap_asks_0_valid(ask_valid[0]),
      .io_snap_asks_1_price(ask_price[1]), .io_snap_asks_1_size(ask_size[1]), .io_snap_asks_1_valid(ask_valid[1]),
      .io_snap_asks_2_price(ask_price[2]), .io_snap_asks_2_size(ask_size[2]), .io_snap_asks_2_valid(ask_valid[2]),
      .io_snap_asks_3_price(ask_price[3]), .io_snap_asks_3_size(ask_size[3]), .io_snap_asks_3_valid(ask_valid[3]),
      .io_snap_asks_4_price(ask_price[4]), .io_snap_asks_4_size(ask_size[4]), .io_snap_asks_4_valid(ask_valid[4]),
      .io_snap_asks_5_price(ask_price[5]), .io_snap_asks_5_size(ask_size[5]), .io_snap_asks_5_valid(ask_valid[5]),
      .io_snap_asks_6_price(ask_price[6]), .io_snap_asks_6_size(ask_size[6]), .io_snap_asks_6_valid(ask_valid[6]),
      .io_snap_asks_7_price(ask_price[7]), .io_snap_asks_7_size(ask_size[7]), .io_snap_asks_7_valid(ask_valid[7]),
      .io_snap_asks_8_price(ask_price[8]), .io_snap_asks_8_size(ask_size[8]), .io_snap_asks_8_valid(ask_valid[8]),
      .io_snap_asks_9_price(ask_price[9]), .io_snap_asks_9_size(ask_size[9]), .io_snap_asks_9_valid(ask_valid[9]),
      .io_snap_imbalance(imbalance),
      .io_snap_midprice(midprice),
      .io_snap_seqNum(seq_num),
      .io_snap_valid(snap_valid)
  );

  genvar i;
  generate
    for (i = 0; i < 10; i = i + 1) begin : g_levels
      assign m_axis_tdata[96*i      +: 32] = bid_price[i];
      assign m_axis_tdata[96*i + 32 +: 32] = bid_size[i];
      assign m_axis_tdata[96*i + 64 +: 32] = {31'b0, bid_valid[i]};
      assign m_axis_tdata[960 + 96*i      +: 32] = ask_price[i];
      assign m_axis_tdata[960 + 96*i + 32 +: 32] = ask_size[i];
      assign m_axis_tdata[960 + 96*i + 64 +: 32] = {31'b0, ask_valid[i]};
    end
  endgenerate
  assign m_axis_tdata[1951:1920] = imbalance;
  assign m_axis_tdata[1983:1952] = midprice;
  assign m_axis_tdata[2015:1984] = seq_num;
  assign m_axis_tvalid = snap_valid;

endmodule
`default_nettype wire
