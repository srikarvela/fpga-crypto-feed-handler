package orderbook

import chisel3._
import chisel3.util._

// Top-level order book: instantiates bid + ask stores, computes signals.
// Parameters are exposed as Chisel generics — depth, price/size bit widths.
//
// AXI-Stream handshake on input: tvalid/tready.
// Output snapshot is registered, valid pulses for one cycle after each update.
class OrderBook(
  val depth:     Int = 10,
  val priceBits: Int = 32,
  val sizeBits:  Int = 32,
) extends Module {

  val io = IO(new Bundle {
    // AXI-Stream slave (from HLS parser)
    val s_axis_tdata  = Input(UInt((priceBits + sizeBits + 1 + 32).W))
    val s_axis_tvalid = Input(Bool())
    val s_axis_tready = Output(Bool())

    // Book snapshot (registered output)
    val snap = Output(new BookSnapshot(priceBits, sizeBits, depth))
  })

  val bidStore = Module(new PriceLevelStore(depth, priceBits, sizeBits, isBid = true))
  val askStore = Module(new PriceLevelStore(depth, priceBits, sizeBits, isBid = false))

  // Decode AXI-Stream payload: {seqNum[31:0], side[0], size[sizeBits-1:0], price[priceBits-1:0]}
  val msg = Wire(new MarketMsg(priceBits, sizeBits))
  msg.price  := io.s_axis_tdata(priceBits - 1, 0)
  msg.size   := io.s_axis_tdata(priceBits + sizeBits - 1, priceBits)
  msg.side   := io.s_axis_tdata(priceBits + sizeBits, priceBits + sizeBits)
  msg.seqNum := io.s_axis_tdata(priceBits + sizeBits + 32, priceBits + sizeBits + 1)
  msg.valid  := io.s_axis_tvalid

  io.s_axis_tready := true.B  // always ready (single-cycle processing)

  val doUpdate = io.s_axis_tvalid

  // Route update to correct side
  bidStore.io.msg    := msg
  bidStore.io.update := doUpdate && msg.side === Side.BID
  askStore.io.msg    := msg
  askStore.io.update := doUpdate && msg.side === Side.ASK

  // --- Compute signals from top-N levels ---
  // Imbalance = (sumBidVol - sumAskVol) / (sumBidVol + sumAskVol), Q16
  val bidVol = bidStore.io.levels.map(l => Mux(l.valid, l.size, 0.U)).reduce(_ +& _)
  val askVol = askStore.io.levels.map(l => Mux(l.valid, l.size, 0.U)).reduce(_ +& _)

  val totalVol = bidVol +& askVol
  // Avoid divide-by-zero; imbalance stays 0 when book is empty
  val imbalance = Mux(
    totalVol === 0.U,
    0.S(32.W),
    ((bidVol.asSInt - askVol.asSInt) << 16.U) / totalVol.asSInt,
  )

  val bestBidValid = bidStore.io.levels(0).valid
  val bestAskValid = askStore.io.levels(0).valid
  val midprice = Mux(
    bestBidValid && bestAskValid,
    (bidStore.io.levels(0).price +& askStore.io.levels(0).price) >> 1,
    0.U,
  )

  // Register output snapshot
  val snap = RegNext({
    val s = Wire(new BookSnapshot(priceBits, sizeBits, depth))
    s.bids      := bidStore.io.levels
    s.asks      := askStore.io.levels
    s.imbalance := imbalance
    s.midprice  := midprice
    s.seqNum    := msg.seqNum
    s.valid     := doUpdate
    s
  })
  io.snap := snap
}

object OrderBookVerilog extends App {
  import chisel3.stage.ChiselStage
  (new ChiselStage).emitVerilog(
    new OrderBook(depth = 10, priceBits = 32, sizeBits = 32),
    Array("--target-dir", "generated"),
  )
}
