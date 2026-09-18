// AXI4-Stream FIFO that never back-pressures its source: s_axis_tready is constant 1 and
// a word arriving while the FIFO is full is dropped and counted. Used behind the HLS
// signal engine so that its out_sig TREADY is a constant and Vivado removes the engine's
// stall logic (a ready -> 1984-flip-flop clock-enable net that could not make 4.000 ns).
// Sized so that it never fills at the specified rates: records arrive at most one per
// 22 pipeline cycles (the parser's II) and the 32-bit DMA side drains one every 7; the
// DEPTH entries absorb DEPTH * 22 cycles of downstream stall before anything is lost.
// Registered output (m_axis_tdata/tvalid change only on the clock).
`default_nettype none
module axis_drop_fifo #(
    parameter WIDTH = 224,
    parameter DEPTH = 32,           // power of two
    parameter AW    = 5             // log2(DEPTH)
) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axis:m_axis, ASSOCIATED_RESET aresetn" *)
    input  wire             aclk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire             aresetn,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TDATA" *)
    input  wire [WIDTH-1:0] s_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TVALID" *)
    input  wire             s_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TREADY" *)
    output wire             s_axis_tready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TDATA" *)
    output reg  [WIDTH-1:0] m_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TVALID" *)
    output reg              m_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TREADY" *)
    input  wire             m_axis_tready,

    output reg  [15:0]      dropped         // words dropped because the FIFO was full
);
  reg [WIDTH-1:0] mem [0:DEPTH-1];
  reg [AW:0] wr_ptr, rd_ptr;               // one extra bit distinguishes full from empty
  wire empty = (wr_ptr == rd_ptr);
  wire full  = (wr_ptr[AW-1:0] == rd_ptr[AW-1:0]) && (wr_ptr[AW] != rd_ptr[AW]);
  assign s_axis_tready = 1'b1;

  wire out_take = m_axis_tvalid && m_axis_tready;   // downstream accepts the current word
  wire can_load = !empty && (!m_axis_tvalid || m_axis_tready);

  always @(posedge aclk) begin
    if (!aresetn) begin
      wr_ptr <= 0; rd_ptr <= 0; m_axis_tvalid <= 1'b0; dropped <= 16'd0;
    end else begin
      // write side: never stalls the source
      if (s_axis_tvalid) begin
        if (!full) begin
          mem[wr_ptr[AW-1:0]] <= s_axis_tdata;
          wr_ptr <= wr_ptr + 1'b1;
        end else begin
          dropped <= dropped + 1'b1;
        end
      end
      // read side: registered output word
      if (can_load) begin
        m_axis_tdata  <= mem[rd_ptr[AW-1:0]];
        m_axis_tvalid <= 1'b1;
        rd_ptr        <= rd_ptr + 1'b1;
      end else if (out_take) begin
        m_axis_tvalid <= 1'b0;
      end
    end
  end
endmodule
`default_nettype wire
