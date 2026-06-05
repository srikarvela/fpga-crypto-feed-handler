package orderbook

import chisel3._
import chisel3.util._

// Single-sided sorted price-level store using a parallel shift-register structure.
// Keeps the top `depth` levels sorted by price (descending for bids, ascending for asks).
// Insert/update/delete in one clock cycle via parallel compare.
//
// isBid=true  → sorted descending (best bid = highest price at index 0)
// isBid=false → sorted ascending  (best ask = lowest  price at index 0)
//
// This is the hardware core — O(depth) area, O(1) latency.
class PriceLevelStore(
  val depth:     Int,
  val priceBits: Int,
  val sizeBits:  Int,
  val isBid:     Boolean,
) extends Module {

  val io = IO(new Bundle {
    val msg    = Input(new MarketMsg(priceBits, sizeBits))
    val update = Input(Bool())                           // pulse to process msg
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

  when(io.update) {
    val price  = io.msg.price
    val size   = io.msg.size
    val delete = size === 0.U

    // --- find insertion slot (parallel compare) ---
    // For bids:  slot where price > store(i).price or !store(i).valid
    // For asks:  slot where price < store(i).price or !store(i).valid
    // We also look for an existing level at the same price (update / delete).

    val matchIdx   = Wire(Vec(depth, Bool()))  // existing level with same price
    val insertBefore = Wire(Vec(depth, Bool())) // new price should go before slot i

    for (i <- 0 until depth) {
      matchIdx(i) := store(i).valid && store(i).price === price
      if (isBid)
        insertBefore(i) := !store(i).valid || price > store(i).price
      else
        insertBefore(i) := !store(i).valid || price < store(i).price
    }

    // Priority encode: first match, then first insertion point
    val hasMatch  = matchIdx.reduce(_ || _)
    val matchPos  = PriorityEncoder(matchIdx)
    val insertPos = PriorityEncoder(insertBefore)

    when(hasMatch) {
      when(delete) {
        // Remove level and shift up
        for (i <- 0 until depth) {
          when(i.U >= matchPos && i.U < (depth - 1).U) {
            store(i) := store(i + 1)
          }.elsewhen(i.U === (depth - 1).U && matchPos <= (depth - 1).U) {
            store(i).valid := false.B
          }
        }
      }.otherwise {
        // Update size in place
        store(matchPos).size := size
      }
    }.elsewhen(!delete) {
      // Insert: shift down from insertPos, drop last entry (it falls off the end)
      for (i <- (0 until depth).reverse) {
        when(i.U > insertPos) {
          store(i) := store(i - 1)
        }.elsewhen(i.U === insertPos) {
          store(i).price := price
          store(i).size  := size
          store(i).valid := true.B
        }
      }
    }
  }
}
