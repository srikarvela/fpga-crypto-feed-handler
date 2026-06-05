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
    dut.clock.step(1)
    dut.io.s_axis_tvalid.poke(false.B)
    dut.clock.step(1) // let output register settle
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

  it should "compute non-zero imbalance with bid-heavy book" in {
    test(new OrderBook(DEPTH, PRICE_BITS, SIZE_BITS)) { dut =>
      dut.io.s_axis_tvalid.poke(false.B)
      dut.clock.step(2)

      sendMsg(dut, 100, 1000, 0, 1)  // bid: 1000
      sendMsg(dut, 101,  200, 1, 2)  // ask:  200

      // bidVol=1000, askVol=200, imbalance > 0 (bid-heavy)
      val imb = dut.io.snap.imbalance.peek().litValue
      assert(imb > 0, s"Expected positive imbalance, got $imb")
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
