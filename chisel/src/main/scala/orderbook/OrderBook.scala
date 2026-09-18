package orderbook

import chisel3._
import chisel3.util._

// Top-level order book: instantiates bid + ask stores and emits a registered snapshot.
// Parameters are exposed as Chisel generics — depth, price/size bit widths.
//
// AXI-Stream input: always ready (an input queue absorbs messages; the stores take one
// every third cycle). The stores compare in the cycle a message is taken, decide in the
// next and apply the update on the edge after; the snapshot (levels + midprice) is
// registered from the updated stores and its valid pulses UPDATE_LATENCY cycles after the
// message edge, so the snapshot the signal engine consumes includes that message.
class OrderBook(
  val depth:     Int = 10,
  val priceBits: Int = 32,
  val sizeBits:  Int = 32,
) extends Module {

  val io = IO(new Bundle {
    // AXI-Stream slave (from HLS parser). tready is constant 1: messages are queued
    // (QUEUE_DEPTH deep) and the stores drain one every 3 cycles; the parser produces at
    // most one per 22, so the queue never fills at the specified rate. If it ever does,
    // the message is dropped and `dropped` counts it (never stalling the upstream HLS
    // pipeline keeps its ready/clock-enable fan-out net, a 4.5 ns path, out of the design).
    val s_axis_tdata  = Input(UInt((priceBits + sizeBits + 1 + 32).W))
    val s_axis_tvalid = Input(Bool())
    val s_axis_tready = Output(Bool())
    val dropped       = Output(UInt(16.W))

    // Book snapshot (registered output)
    val snap = Output(new BookSnapshot(priceBits, sizeBits, depth))
  })

  val bidStore = Module(new PriceLevelStore(depth, priceBits, sizeBits, isBid = true))
  val askStore = Module(new PriceLevelStore(depth, priceBits, sizeBits, isBid = false))

  // Input queue: always ready to the AXI-Stream, drops (and counts) on overflow
  val inQ = Module(new Queue(UInt((priceBits + sizeBits + 1 + 32).W), OrderBook.QUEUE_DEPTH))
  inQ.io.enq.bits  := io.s_axis_tdata
  inQ.io.enq.valid := io.s_axis_tvalid && inQ.io.enq.ready
  io.s_axis_tready := true.B
  val dropCount = RegInit(0.U(16.W))
  when(io.s_axis_tvalid && !inQ.io.enq.ready) { dropCount := dropCount + 1.U }
  io.dropped := dropCount

  // Take a message from the queue into a register (the queue's read mux would otherwise
  // sit in front of the stores' 32-bit comparators: 5.1 ns post-route), then decode.
  // The three-stage store must see the updated book before the next compare, so a queued
  // message is taken every third cycle (the two cycles after a take are busy).
  val take     = inQ.io.deq.fire
  val busy1    = RegNext(take, false.B)
  val busy2    = RegNext(busy1, false.B)
  inQ.io.deq.ready := !(busy1 || busy2)
  val word     = RegEnable(inQ.io.deq.bits, take)
  val doUpdate = RegNext(take, false.B)

  // Decode AXI-Stream payload: {seqNum[31:0], side[0], size[sizeBits-1:0], price[priceBits-1:0]}
  val msg = Wire(new MarketMsg(priceBits, sizeBits))
  msg.price  := word(priceBits - 1, 0)
  msg.size   := word(priceBits + sizeBits - 1, priceBits)
  msg.side   := word(priceBits + sizeBits, priceBits + sizeBits)
  msg.seqNum := word(priceBits + sizeBits + 32, priceBits + sizeBits + 1)
  msg.valid  := doUpdate

  // Route update to correct side
  bidStore.io.msg    := msg
  bidStore.io.update := doUpdate && msg.side === Side.BID
  askStore.io.msg    := msg
  askStore.io.update := doUpdate && msg.side === Side.ASK

  // --- Snapshot: registered from the *post-update* level stores ---
  // Cycle 0: message on s_axis (always accepted) is written into the input queue.
  // Cycle 1: the message is taken from the queue into the message register.
  // Cycle 2: the stores compare and register the compares.
  // Cycle 3: the stores encode positions and register their per-slot decisions.
  // Cycle 4: the stores apply the decisions on the edge.
  // Cycle 5: the stores hold the new book; midprice is one 33-bit add off them; the
  //          snapshot register captures levels + midprice with valid = update delayed 3x.
  // Cycle 6: io.snap.valid is high and io.snap holds the book that includes the message.
  // (The first version registered the stores on the same edge as the update, so its
  // valid cycle carried the pre-update book.)
  val updateD1 = ShiftRegister(doUpdate, OrderBook.STORE_LATENCY, false.B, true.B)
  val seqPipe  = ShiftRegister(msg.seqNum, OrderBook.STORE_LATENCY)
  val seqHold  = RegInit(0.U(32.W))            // sequence number of the last message applied
  when(updateD1) { seqHold := seqPipe }

  val bestBidValid = bidStore.io.levels(0).valid
  val bestAskValid = askStore.io.levels(0).valid
  val midprice = Mux(
    bestBidValid && bestAskValid,
    (bidStore.io.levels(0).price +& askStore.io.levels(0).price) >> 1,
    0.U,
  )

  val snap = RegNext({
    val s = Wire(new BookSnapshot(priceBits, sizeBits, depth))
    s.bids      := bidStore.io.levels
    s.asks      := askStore.io.levels
    s.midprice  := midprice
    s.seqNum    := Mux(updateD1, seqPipe, seqHold)
    s.valid     := updateD1
    s
  })
  io.snap := snap
}

object OrderBook {
  val QUEUE_DEPTH = 4
  // Cycles from the message register to io.snap.valid (decide + apply + snapshot register).
  val STORE_LATENCY = 3
  // Cycles from the edge on which a message is accepted on s_axis to io.snap.valid, when the
  // queue is empty: queue (1) + message register (1) + STORE_LATENCY.
  val UPDATE_LATENCY = 2 + STORE_LATENCY
}

object OrderBookVerilog extends App {
  import chisel3.stage.ChiselStage
  (new ChiselStage).emitVerilog(
    new OrderBook(depth = 10, priceBits = 32, sizeBits = 32),
    Array("--target-dir", "generated"),
  )
}
