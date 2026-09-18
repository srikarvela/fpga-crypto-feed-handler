`timescale 1ns/1ps
// Self-checking Icarus testbench for axis_drop_fifo: in-order delivery under downstream
// stalls, correct drop counting when the FIFO is full, no duplicates or losses otherwise.
module tb_axis_drop_fifo;
  localparam W = 32, D = 8, AW = 3;
  reg clk = 0; always #2 clk = ~clk;
  reg rstn = 0;
  reg  [W-1:0] s_tdata = 0; reg s_tvalid = 0; wire s_tready;
  wire [W-1:0] m_tdata; wire m_tvalid; reg m_tready = 0; wire [15:0] dropped;
  axis_drop_fifo #(.WIDTH(W), .DEPTH(D), .AW(AW)) dut (
    .aclk(clk), .aresetn(rstn), .s_axis_tdata(s_tdata), .s_axis_tvalid(s_tvalid), .s_axis_tready(s_tready),
    .m_axis_tdata(m_tdata), .m_axis_tvalid(m_tvalid), .m_axis_tready(m_tready), .dropped(dropped));
  integer sent = 0, got = 0, expect_next = 1, errors = 0, i;
  // collect outputs
  always @(posedge clk) if (rstn && m_tvalid && m_tready) begin
    if (m_tdata !== expect_next) begin $display("ERROR: got %0d expected %0d", m_tdata, expect_next); errors = errors + 1; end
    expect_next = expect_next + 1; got = got + 1;
  end
  task send(input integer n); begin
    for (i = 0; i < n; i = i + 1) begin
      @(negedge clk); s_tdata = sent + 1; s_tvalid = 1; sent = sent + 1;
    end
    @(negedge clk); s_tvalid = 0;
  end endtask
  initial begin
    #10 rstn = 1;
    // phase 1: downstream always ready, 20 words back-to-back -> all delivered in order
    m_tready = 1; send(20); repeat (5) @(posedge clk);
    if (got != 20 || dropped != 0) begin $display("ERROR phase1 got=%0d dropped=%0d", got, dropped); errors = errors + 1; end
    if (s_tready !== 1'b1) begin $display("ERROR: tready not constant 1"); errors = errors + 1; end
    // phase 2: downstream stalled; send D words (fill: D in memory, none loaded since output stalled? the
    //          output register takes one, so D+1 fit) then more -> extras dropped
    m_tready = 0; send(D + 1); send(3);       // 3 dropped
    if (dropped != 3) begin $display("ERROR phase2 dropped=%0d expected 3", dropped); errors = errors + 1; end
    // phase 3: release downstream; the D+1 buffered words come out in order, then the stream continues
    expect_next = 21; // words 21..21+D were kept, 3 after them were dropped
    m_tready = 1; repeat (D + 4) @(posedge clk);
    if (got != 20 + D + 1) begin $display("ERROR phase3 got=%0d expected %0d", got, 20 + D + 1); errors = errors + 1; end
    expect_next = sent + 1;                    // the next word sent continues the sequence
    send(5); repeat (4) @(posedge clk);
    if (got != 20 + D + 1 + 5) begin $display("ERROR phase4 got=%0d", got); errors = errors + 1; end
    // phase 4: intermittent ready (every other cycle) with continuous input at half rate -> no drops
    m_tready = 0;
    for (i = 0; i < 40; i = i + 1) begin @(negedge clk); m_tready = ~m_tready; s_tvalid = (i % 2 == 0); if (i % 2 == 0) begin s_tdata = sent + 1; sent = sent + 1; end end
    @(negedge clk); s_tvalid = 0; m_tready = 1; repeat (12) @(posedge clk);
    if (dropped != 3) begin $display("ERROR phase4 dropped=%0d", dropped); errors = errors + 1; end
    if (got != sent - 3) begin $display("ERROR final got=%0d sent=%0d dropped=%0d", got, sent, dropped); errors = errors + 1; end
    if (errors == 0) $display("TEST PASSED: %0d sent, %0d delivered in order, %0d dropped as expected", sent, got, dropped);
    else $display("TEST FAILED: %0d errors", errors);
    $finish;
  end
endmodule
