"""
Software golden model for the hardware order book.
Reads the binary replay file, processes every message, and produces
a JSON file of snapshots (seq_num, bids, asks, imbalance, midprice,
microprice, spread) that can be diffed against hardware output.
"""

import struct
import json
import numpy as np
from pathlib import Path
from collections import OrderedDict

TICK_SIZE  = 100    # must match HLS TICK_SIZE
DEPTH      = 10     # must match Chisel depth parameter
WIRE_FMT   = "<cBIQQ"
WIRE_BYTES = struct.calcsize(WIRE_FMT)
assert WIRE_BYTES == 22


class OrderBookRef:
    def __init__(self, depth: int = DEPTH):
        self.depth = depth
        self.bids: dict[int, int] = {}  # price_ticks → size
        self.asks: dict[int, int] = {}

    def apply(self, msg_type: bytes, side: int, price_raw: int, size_raw: int):
        price_ticks = price_raw // TICK_SIZE
        book = self.bids if side == 0 else self.asks

        if msg_type == b'D' or size_raw == 0:
            book.pop(price_ticks, None)
        else:
            book[price_ticks] = size_raw

    def top_bids(self) -> list[tuple[int, int]]:
        return sorted(self.bids.items(), key=lambda x: -x[0])[:self.depth]

    def top_asks(self) -> list[tuple[int, int]]:
        return sorted(self.asks.items(), key=lambda x: x[0])[:self.depth]

    def snapshot(self, seq: int) -> dict:
        bids = self.top_bids()
        asks = self.top_asks()

        bid_vol = sum(s for _, s in bids)
        ask_vol = sum(s for _, s in asks)
        total   = bid_vol + ask_vol

        imbalance  = int((bid_vol - ask_vol) / total * (1 << 16)) if total else 0
        midprice   = (bids[0][0] + asks[0][0]) // 2 if bids and asks else 0
        microprice = 0
        if bids and asks and total:
            microprice = (bids[0][0] * ask_vol + asks[0][0] * bid_vol) // total
        spread = (asks[0][0] - bids[0][0]) if bids and asks else 0

        vwap_bid = int(sum(p * s for p, s in bids) / bid_vol * 256) if bid_vol else 0
        vwap_ask = int(sum(p * s for p, s in asks) / ask_vol * 256) if ask_vol else 0

        return {
            "seq_num":    seq,
            "bids":       bids,
            "asks":       asks,
            "imbalance":  imbalance,
            "midprice":   midprice,
            "microprice": microprice,
            "spread":     spread,
            "vwap_bid":   vwap_bid,
            "vwap_ask":   vwap_ask,
        }


def process_replay(bin_path: str, out_path: str | None = None) -> list[dict]:
    """Process a binary replay file and return list of snapshots."""
    book = OrderBookRef()
    snaps = []
    data  = Path(bin_path).read_bytes()
    n_msg = len(data) // WIRE_BYTES

    for i in range(n_msg):
        chunk = data[i * WIRE_BYTES : (i + 1) * WIRE_BYTES]
        msg_type, side, seq, price_raw, size_raw = struct.unpack(WIRE_FMT, chunk)
        book.apply(msg_type, side, price_raw, size_raw)
        snaps.append(book.snapshot(seq))

    if out_path:
        with open(out_path, "w") as f:
            json.dump(snaps, f, indent=2)
        print(f"Wrote {len(snaps)} snapshots → {out_path}")

    return snaps


def diff_hw_vs_ref(hw_json: str, ref_json: str, tolerance: int = 1) -> bool:
    """
    Compare hardware output JSON against reference golden model.
    tolerance: allowed integer difference for fixed-point signals.
    Returns True if all checks pass.
    """
    with open(hw_json)  as f: hw  = json.load(f)
    with open(ref_json) as f: ref = json.load(f)

    assert len(hw) == len(ref), f"Length mismatch: hw={len(hw)} ref={len(ref)}"
    errors = 0

    for i, (h, r) in enumerate(zip(hw, ref)):
        seq = r["seq_num"]
        for key in ("imbalance", "midprice", "microprice", "spread"):
            if abs(int(h[key]) - int(r[key])) > tolerance:
                print(f"[seq={seq}] {key}: hw={h[key]} ref={r[key]} MISMATCH")
                errors += 1
        # Check top bid/ask prices
        for j, (hb, rb) in enumerate(zip(h["bids"][:3], r["bids"][:3])):
            if hb[0] != rb[0]:
                print(f"[seq={seq}] bids[{j}].price: hw={hb[0]} ref={rb[0]} MISMATCH")
                errors += 1

    if errors == 0:
        print(f"PASS — {len(hw)} snapshots match (tolerance={tolerance})")
    else:
        print(f"FAIL — {errors} mismatches in {len(hw)} snapshots")
    return errors == 0


if __name__ == "__main__":
    import sys
    bin_path = sys.argv[1] if len(sys.argv) > 1 else "python/vectors/btcusd_snapshot.bin"
    out_path = sys.argv[2] if len(sys.argv) > 2 else "python/vectors/golden_snaps.json"
    process_replay(bin_path, out_path)
