package orderbook

import chisel3._
import chisel3.util._

// Single-sided sorted price-level store using a parallel shift-register structure.
// Keeps the top `depth` levels sorted by price (descending for bids, ascending for asks).
// Insert/update/delete via parallel compare, in three register stages:
//
//   stage 1 (the cycle `update` is high): every slot is compared with the message price
//           in parallel (equal / should-insert-before); the 2 x depth compare bits are
//           registered together with the message.
//   stage 2: priority-encode the registered compares into the match / insert position and
//           derive each slot's decision (hold / take the level above / take the level
//           below / load the message / update size / clear); register the decisions.
//   stage 3: each slot's registers are written from its registered decision.
//
// The first version did all of this in one cycle; post-route the insert-position decode
// fanned out to every slot's clock enable (a 647-load net, 7.8 ns) and the store alone
// could not run faster than 124 MHz; with compare + decide in one stage the routing from
// twenty comparators into the encoders and back out was still 6.2 ns (160 MHz). The
// split costs two cycles of latency and means a new message can be accepted every third
// cycle (the compare must see the updated store), which the upstream parser (one message
// per 22 cycles) never notices.
//
// isBid=true  → sorted descending (best bid = highest price at index 0)
// isBid=false → sorted ascending  (best ask = lowest  price at index 0)
//
// This is the hardware core — O(depth) area, O(1) latency in the number of levels.
class PriceLevelStore(
  val depth:     Int,
  val priceBits: Int,
  val sizeBits:  Int,
  val isBid:     Boolean,
) extends Module {

  val io = IO(new Bundle {
    val msg    = Input(new MarketMsg(priceBits, sizeBits))
    val update = Input(Bool())                           // pulse to process msg (at most once every 3 cycles)
    val levels = Output(Vec(depth, new Level(priceBits, sizeBits)))
  })

  // Register file: depth slots, always kept sorted
  val store = RegInit(VecInit(Seq.fill(depth) {
    val l = Wire(new Level(priceBits, sizeBits))
    l.price := 0.U
    l.size  := 0.U
    l.valid := false.B
    l
  }))

  io.levels := store

  // ---- Stage 1: parallel compare ----
  val price  = io.msg.price
  val size   = io.msg.size

  val matchIdx     = Wire(Vec(depth, Bool()))  // existing level with same price
  val insertBefore = Wire(Vec(depth, Bool()))  // new price should go before slot i
  for (i <- 0 until depth) {
    matchIdx(i) := store(i).valid && store(i).price === price
    if (isBid)
      insertBefore(i) := !store(i).valid || price > store(i).price
    else
      insertBefore(i) := !store(i).valid || price < store(i).price
  }
  val matchIdxR     = RegNext(matchIdx)
  val insertBeforeR = RegNext(insertBefore)
  val updateR1      = RegNext(io.update, false.B)
  val priceR1       = RegNext(price)
  val sizeR1        = RegNext(size)
  val deleteR1      = RegNext(size === 0.U)

  // ---- Stage 2: encode positions and decide per slot ----
  val hasMatch  = matchIdxR.reduce(_ || _)
  val matchPos  = PriorityEncoder(matchIdxR)
  val insertPos = PriorityEncoder(insertBeforeR)

  // One-hot-ish decision per slot (all false = hold)
  val takeBelow  = Wire(Vec(depth, Bool()))   // store(i) := store(i+1)   (delete: shift up)
  val clearLast  = Wire(Bool())               // store(depth-1).valid := false (delete)
  val setSize    = Wire(Vec(depth, Bool()))   // store(i).size := size   (update in place)
  val takeAbove  = Wire(Vec(depth, Bool()))   // store(i) := store(i-1)   (insert: shift down)
  val loadNew    = Wire(Vec(depth, Bool()))   // store(i) := {price, size, valid}
  for (i <- 0 until depth) {
    takeBelow(i) := updateR1 && hasMatch && deleteR1 && (i < depth - 1).B && (i.U >= matchPos)
    setSize(i)   := updateR1 && hasMatch && !deleteR1 && (i.U === matchPos)
    takeAbove(i) := updateR1 && !hasMatch && !deleteR1 && (i > 0).B && (i.U > insertPos)
    loadNew(i)   := updateR1 && !hasMatch && !deleteR1 && (i.U === insertPos)
  }
  clearLast := updateR1 && hasMatch && deleteR1

  val takeBelowR = RegNext(takeBelow, VecInit(Seq.fill(depth)(false.B)))
  val clearLastR = RegNext(clearLast, false.B)
  val setSizeR   = RegNext(setSize,   VecInit(Seq.fill(depth)(false.B)))
  val takeAboveR = RegNext(takeAbove, VecInit(Seq.fill(depth)(false.B)))
  val loadNewR   = RegNext(loadNew,   VecInit(Seq.fill(depth)(false.B)))
  val priceR     = RegNext(priceR1)
  val sizeR      = RegNext(sizeR1)

  // ---- Stage 3: apply (the neighbour references are guarded at the Scala level so slot 0
  //      never indexes store(-1) and the last slot never indexes store(depth)) ----
  for (i <- 0 until depth) {
    when(loadNewR(i)) {
      store(i).price := priceR
      store(i).size  := sizeR
      store(i).valid := true.B
    }
    if (i > 0)         { when(takeAboveR(i)) { store(i) := store(i - 1) } }
    if (i < depth - 1) { when(takeBelowR(i)) { store(i) := store(i + 1) } }
    when(setSizeR(i)) { store(i).size := sizeR }
  }
  when(clearLastR) {
    store(depth - 1).valid := false.B
  }
}
