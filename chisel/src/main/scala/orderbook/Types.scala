package orderbook

import chisel3._
import chisel3.util._

// Fixed-point price: integer ticks (price = ticks * tickSize, done off-chip)
// size: quantity in base asset, scaled by 1e6 (so 1.5 BTC = 1_500_000)

object Side {
  val BID = 0.U(1.W)
  val ASK = 1.U(1.W)
}

// Normalized market-data message from the HLS parser (AXI-Stream payload)
class MarketMsg(val priceBits: Int, val sizeBits: Int) extends Bundle {
  val price  = UInt(priceBits.W)
  val size   = UInt(sizeBits.W)   // 0 = delete this level
  val side   = UInt(1.W)          // 0=bid, 1=ask
  val seqNum = UInt(32.W)
  val valid  = Bool()
}

// One order-book price level
class Level(val priceBits: Int, val sizeBits: Int) extends Bundle {
  val price = UInt(priceBits.W)
  val size  = UInt(sizeBits.W)
  val valid = Bool()
}

// Output snapshot: top-N bid and ask levels + midprice. Volume-derived signals
// (imbalance, microprice, VWAP) are computed downstream by the HLS signal engine from
// these levels; the book itself carries no divider (the earlier single-cycle
// imbalance divide was a 310 ns combinational path).
class BookSnapshot(val priceBits: Int, val sizeBits: Int, val depth: Int) extends Bundle {
  val bids      = Vec(depth, new Level(priceBits, sizeBits))
  val asks      = Vec(depth, new Level(priceBits, sizeBits))
  val midprice  = UInt(priceBits.W) // (best_bid + best_ask) / 2 in ticks
  val seqNum    = UInt(32.W)
  val valid     = Bool()
}
