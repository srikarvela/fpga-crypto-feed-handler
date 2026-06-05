"""
Unit tests for the golden model itself — verifies sorted insert, delete,
imbalance arithmetic, and microprice before we trust it as a hw checker.
"""

import pytest
from order_book_ref import OrderBookRef, process_replay
import struct, tempfile, os

WIRE_FMT = "<cBIQQ"
TICK_SIZE = 100

def make_bin(*msgs):
    """Pack list of (type, side, seq, price_usd, size_btc) into bytes."""
    buf = b""
    for mtype, side, seq, price_usd, size_btc in msgs:
        price_r = int(round(price_usd * 1e8))
        size_r  = int(round(size_btc  * 1e6))
        buf += struct.pack(WIRE_FMT, mtype, side, seq, price_r, size_r)
    return buf


def test_bid_sorted_descending():
    b = OrderBookRef(depth=5)
    b.apply(b'A', 0, 10_000_000_000, 1_000_000)  # 100.00
    b.apply(b'A', 0, 10_200_000_000, 500_000)    # 102.00
    b.apply(b'A', 0, 10_100_000_000, 250_000)    # 101.00
    bids = b.top_bids()
    assert bids[0][0] > bids[1][0] > bids[2][0], "bids not descending"


def test_ask_sorted_ascending():
    b = OrderBookRef(depth=5)
    b.apply(b'A', 1, 10_300_000_000, 100_000)  # 103
    b.apply(b'A', 1, 10_100_000_000, 200_000)  # 101 (best)
    b.apply(b'A', 1, 10_200_000_000, 150_000)  # 102
    asks = b.top_asks()
    assert asks[0][0] < asks[1][0] < asks[2][0], "asks not ascending"


def test_delete():
    b = OrderBookRef(depth=5)
    b.apply(b'A', 0, 10_000_000_000, 1_000_000)
    b.apply(b'A', 0, 10_200_000_000, 500_000)
    b.apply(b'D', 0, 10_000_000_000, 0)
    bids = b.top_bids()
    prices = [p for p, _ in bids]
    assert 10_000_000_000 // TICK_SIZE not in prices


def test_imbalance_bid_heavy():
    b = OrderBookRef(depth=5)
    b.apply(b'A', 0, 10_000_000_000, 1_000_000)  # bid 1000 units
    b.apply(b'A', 1, 10_100_000_000,   200_000)  # ask  200 units
    snap = b.snapshot(1)
    assert snap["imbalance"] > 0, "bid-heavy book should have positive imbalance"


def test_midprice():
    b = OrderBookRef(depth=5)
    b.apply(b'A', 0, 10_000_000_000, 1_000_000)  # bid 100.00
    b.apply(b'A', 1, 10_200_000_000,   500_000)  # ask 102.00
    snap = b.snapshot(1)
    # midprice = (100 + 102) ticks / 2 = 101 ticks (price in ticks = raw//100)
    assert snap["midprice"] == (10_000_000_000 // TICK_SIZE + 10_200_000_000 // TICK_SIZE) // 2


def test_replay_file():
    msgs = [
        (b'A', 0, 1, 100.0, 1.5),
        (b'A', 1, 2, 101.0, 0.5),
        (b'U', 0, 3, 100.0, 2.0),
        (b'D', 0, 4, 100.0, 0.0),
    ]
    raw = make_bin(*msgs)
    with tempfile.NamedTemporaryFile(delete=False, suffix=".bin") as f:
        f.write(raw)
        fname = f.name
    try:
        snaps = process_replay(fname)
        assert len(snaps) == 4
        # After msg 4 (delete bid at 100), no bids
        assert snaps[3]["bids"] == []
    finally:
        os.unlink(fname)
