"""
PYNQ-Z2 driver (Tier 3): loads the bitstream, streams replay data via DMA,
reads back signal outputs, and compares against the Python golden model.

Run on the PYNQ board:
    python3 pynq_driver.py ../../python/vectors/btcusd_snapshot.bin
"""

import numpy as np
import struct
import sys
import json
from pathlib import Path

try:
    from pynq import Overlay, allocate
    PYNQ_AVAILABLE = True
except ImportError:
    PYNQ_AVAILABLE = False
    print("[WARNING] pynq package not found — running in dry-run mode")

BITSTREAM   = "/home/xilinx/fpga_crypto_feed/feed_handler_bd_wrapper.bit"
WIRE_FMT    = "<cBIQQ"
WIRE_BYTES  = struct.calcsize(WIRE_FMT)
assert WIRE_BYTES == 22

# SignalOut struct from HLS (matches signals.h layout, packed)
# imbalance(4) + microprice(4) + spread(4) + vwap_bid(4) + vwap_ask(4) + seq(4) + valid(1) → 25B padded to 28
SIG_FMT   = "<iiIiiIB"
SIG_BYTES = struct.calcsize(SIG_FMT)


def load_replay(path: str) -> bytes:
    return Path(path).read_bytes()


def stream_and_collect(replay_bytes: bytes) -> list[dict]:
    """Send replay data to FPGA via DMA, collect signal outputs."""
    if not PYNQ_AVAILABLE:
        print("[dry-run] Would load bitstream and DMA", len(replay_bytes), "bytes")
        return []

    ol  = Overlay(BITSTREAM)
    dma = ol.axi_dma_0

    n_msg = len(replay_bytes) // WIRE_BYTES

    # Allocate contiguous buffers
    tx_buf = allocate(shape=(len(replay_bytes),), dtype=np.uint8)
    rx_buf = allocate(shape=(n_msg * SIG_BYTES,), dtype=np.uint8)

    np.copyto(tx_buf, np.frombuffer(replay_bytes, dtype=np.uint8))

    # Start DMA transfer (non-blocking)
    dma.sendchannel.transfer(tx_buf)
    dma.recvchannel.transfer(rx_buf)
    dma.sendchannel.wait()
    dma.recvchannel.wait()

    results = []
    raw = bytes(rx_buf)
    for i in range(n_msg):
        chunk = raw[i * SIG_BYTES : (i + 1) * SIG_BYTES]
        if len(chunk) < SIG_BYTES:
            break
        imb, micro, spread, vwap_b, vwap_a, seq, valid = struct.unpack(SIG_FMT, chunk)
        if valid:
            results.append({
                "seq_num":    seq,
                "imbalance":  imb,
                "microprice": micro,
                "spread":     spread,
                "vwap_bid":   vwap_b,
                "vwap_ask":   vwap_a,
            })

    tx_buf.freebuffer()
    rx_buf.freebuffer()
    return results


def run(replay_path: str, golden_path: str | None = None):
    replay = load_replay(replay_path)
    hw_results = stream_and_collect(replay)

    out_path = replay_path.replace(".bin", "_hw_out.json")
    with open(out_path, "w") as f:
        json.dump(hw_results, f, indent=2)
    print(f"Hardware output → {out_path} ({len(hw_results)} records)")

    if golden_path:
        import sys, os
        sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../../python/golden"))
        from order_book_ref import diff_hw_vs_ref
        diff_hw_vs_ref(out_path, golden_path)


if __name__ == "__main__":
    replay_path = sys.argv[1] if len(sys.argv) > 1 else "../../python/vectors/btcusd_snapshot.bin"
    golden_path = sys.argv[2] if len(sys.argv) > 2 else None
    run(replay_path, golden_path)
