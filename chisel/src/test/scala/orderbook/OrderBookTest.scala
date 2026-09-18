package orderbook

import chisel3._
import chiseltest._
import org.scalatest.flatspec.AnyFlatSpec

class OrderBookTest extends AnyFlatSpec with ChiselScalatestTester {

  val PRICE_BITS = 32
  val SIZE_BITS  = 32
  val DEPTH      = 5

  def pack(price: Long, size: Long, side: Int, seq: Long): BigInt = {
    var v = BigInt(price)
    v |= BigInt(size) << PRICE_BITS
    v |= BigInt(side) << (PRICE_BITS + SIZE_BITS)
    v |= BigInt(seq)  << (PRICE_BITS + SIZE_BITS + 1)
    v
  }

  def sendMsg(dut: OrderBook, price: Long, size: Long, side: Int, seq: Long): Unit = {
    dut.io.s_axis_tdata.poke(pack(price, size, side, seq).U)
    dut.io.s_axis_tvalid.poke(true.B)
    dut.io.s_axis_tready.expect(true.B)  // always ready
    dut.clock.step(1)                    // accept into the queue
    dut.io.s_axis_tvalid.poke(false.B)
    dut.clock.step(OrderBook.UPDATE_LATENCY) // take, decide, apply, snapshot register
  }

  behavior of "OrderBook"

  it should "insert bid levels in sorted order (descending)" in {
    test(new OrderBook(DEPTH, PRICE_BITS, SIZE_BITS)) { dut =>
      dut.io.s_axis_tvalid.poke(false.B)
      dut.clock.step(2)

      sendMsg(dut, 100, 50, 0, 1)  // bid at 100
      sendMsg(dut, 102, 30, 0, 2)  // bid at 102 (should become best)
      sendMsg(dut, 101, 20, 0, 3)  // bid at 101 (should be second)

      // Best bid at index 0 should be 102
      dut.io.snap.bids(0).price.expect(102.U)
      dut.io.snap.bids(1).price.expect(101.U)
      dut.io.snap.bids(2).price.expect(100.U)
    }
  }

  it should "insert ask levels in sorted order (ascending)" in {
    test(new OrderBook(DEPTH, PRICE_BITS, SIZE_BITS)) { dut =>
      dut.io.s_axis_tvalid.poke(false.B)
      dut.clock.step(2)

      sendMsg(dut, 105, 10, 1, 1)  // ask at 105
      sendMsg(dut, 103, 25, 1, 2)  // ask at 103 (best ask)
      sendMsg(dut, 104, 15, 1, 3)  // ask at 104 (second)

      dut.io.snap.asks(0).price.expect(103.U)
      dut.io.snap.asks(1).price.expect(104.U)
      dut.io.snap.asks(2).price.expect(105.U)
    }
  }

  it should "delete a level (size=0)" in {
    test(new OrderBook(DEPTH, PRICE_BITS, SIZE_BITS)) { dut =>
      dut.io.s_axis_tvalid.poke(false.B)
      dut.clock.step(2)

      sendMsg(dut, 100, 50, 0, 1)
      sendMsg(dut, 102, 30, 0, 2)
      sendMsg(dut, 101, 20, 0, 3)
      // Delete level at 101
      sendMsg(dut, 101, 0, 0, 4)

      dut.io.snap.bids(0).price.expect(102.U)
      dut.io.snap.bids(1).price.expect(100.U)
      dut.io.snap.bids(2).valid.expect(false.B)
    }
  }

  it should "update size in place" in {
    test(new OrderBook(DEPTH, PRICE_BITS, SIZE_BITS)) { dut =>
      dut.io.s_axis_tvalid.poke(false.B)
      dut.clock.step(2)

      sendMsg(dut, 100, 50, 0, 1)
      sendMsg(dut, 100, 99, 0, 2)  // update size at 100

      dut.io.snap.bids(0).price.expect(100.U)
      dut.io.snap.bids(0).size.expect(99.U)
    }
  }

  it should "raise snap.valid OrderBook.UPDATE_LATENCY cycles after the accept edge, carrying the post-update book" in {
    test(new OrderBook(DEPTH, PRICE_BITS, SIZE_BITS)) { dut =>
      dut.io.s_axis_tvalid.poke(false.B)
      dut.clock.step(2)

      dut.io.s_axis_tdata.poke(pack(100, 50, 0, 7).U)
      dut.io.s_axis_tvalid.poke(true.B)
      dut.io.s_axis_tready.expect(true.B)
      dut.clock.step(1)                         // edge 1: queued
      dut.io.s_axis_tvalid.poke(false.B)
      dut.io.s_axis_tready.expect(true.B)       // still ready: the queue absorbs
      for (c <- 1 until OrderBook.UPDATE_LATENCY) {
        dut.io.snap.valid.expect(false.B, s"snap.valid early at cycle $c")
        dut.clock.step(1)
      }
      dut.io.snap.valid.expect(false.B)         // UPDATE_LATENCY - 1 edges after the accept edge: not yet
      dut.clock.step(1)
      dut.io.snap.valid.expect(true.B)          // exactly UPDATE_LATENCY edges after the accept edge
      dut.io.snap.bids(0).price.expect(100.U)   // the message is already in the snapshot
      dut.io.snap.bids(0).size.expect(50.U)
      dut.io.snap.seqNum.expect(7.U)
      dut.clock.step(1)
      dut.io.snap.valid.expect(false.B)         // one-cycle pulse
      dut.io.snap.bids(0).price.expect(100.U)   // data stays
      dut.io.dropped.expect(0.U)
    }
  }

  it should "compute midprice" in {
    test(new OrderBook(DEPTH, PRICE_BITS, SIZE_BITS)) { dut =>
      dut.io.s_axis_tvalid.poke(false.B)
      dut.clock.step(2)

      sendMsg(dut, 100, 50, 0, 1)   // best bid = 100
      sendMsg(dut, 102, 30, 1, 2)   // best ask = 102

      dut.io.snap.midprice.expect(101.U)  // (100+102)/2
    }
  }

  it should "absorb QUEUE_DEPTH back-to-back messages (one per cycle) without dropping and apply them in order" in {
    test(new OrderBook(DEPTH, PRICE_BITS, SIZE_BITS)) { dut =>
      dut.io.s_axis_tvalid.poke(false.B)
      dut.clock.step(2)
      val msgs = Seq((100L, 10L, 0, 1L), (102L, 20L, 0, 2L), (101L, 30L, 0, 3L), (102L, 0L, 0, 4L))
      for ((p, sz, side, seq) <- msgs) {
        dut.io.s_axis_tdata.poke(pack(p, sz, side, seq).U)
        dut.io.s_axis_tvalid.poke(true.B)
        dut.io.s_axis_tready.expect(true.B)
        dut.clock.step(1)
      }
      dut.io.s_axis_tvalid.poke(false.B)
      dut.clock.step(3 * msgs.length + OrderBook.UPDATE_LATENCY)   // drain at one per 3 cycles
      dut.io.dropped.expect(0.U)
      dut.io.snap.bids(0).price.expect(101.U)   // 102 was deleted
      dut.io.snap.bids(0).size.expect(30.U)
      dut.io.snap.bids(1).price.expect(100.U)
      dut.io.snap.bids(2).valid.expect(false.B)
      dut.io.snap.seqNum.expect(4.U)
    }
  }

  it should "count a dropped message when more than QUEUE_DEPTH arrive faster than the stores drain" in {
    test(new OrderBook(DEPTH, PRICE_BITS, SIZE_BITS)) { dut =>
      dut.io.s_axis_tvalid.poke(false.B)
      dut.clock.step(2)
      // Messages on consecutive cycles while the stores take one every third cycle: with
      // QUEUE_DEPTH = 4 the queue is full after the 6th arrival and the 7th is dropped.
      for (i <- 0 until OrderBook.QUEUE_DEPTH + 3) {
        dut.io.s_axis_tdata.poke(pack(200 + i, 1, 0, 10 + i).U)
        dut.io.s_axis_tvalid.poke(true.B)
        dut.clock.step(1)
      }
      dut.io.s_axis_tvalid.poke(false.B)
      dut.clock.step(3 * (OrderBook.QUEUE_DEPTH + 3) + OrderBook.UPDATE_LATENCY)
      dut.io.dropped.expect(1.U)
    }
  }

  it should "not exceed depth (oldest marginal level drops off)" in {
    test(new OrderBook(DEPTH, PRICE_BITS, SIZE_BITS)) { dut =>
      dut.io.s_axis_tvalid.poke(false.B)
      dut.clock.step(2)

      // Insert DEPTH+2 bid levels
      for (i <- 1 to DEPTH + 2) {
        sendMsg(dut, i * 10, 10, 0, i)
      }
      // Only top DEPTH bids survive; level at price=10 dropped
      dut.io.snap.bids(DEPTH - 1).valid.expect(true.B)
      // All valid slots should have price >= 20
      for (i <- 0 until DEPTH) {
        val p = dut.io.snap.bids(i).price.peek().litValue
        assert(p > 10, s"Slot $i has price $p, expected > 10")
      }
    }
  }
}
