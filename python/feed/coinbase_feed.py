"""
Coinbase Advanced Trade WebSocket L2 feed adapter.
Subscribes to the BTC-USD level2 channel, normalizes messages to the
22-byte binary wire format consumed by the HLS parser, and either
  (a) writes a replay file (.bin) for test vectors, or
  (b) sends live to the PYNQ board over UDP.
"""

import asyncio
import json
import struct
import time
import websockets

WS_URL = "wss://advanced-trade-api.coinbase.com"
PRODUCT = "BTC-USD"
TICK_SIZE = 100  # satoshis per tick — must match HLS TICK_SIZE

# Wire format: 22 bytes little-endian
#   msg_type : char  (A/U/D)
#   side     : uint8 (0=bid, 1=ask)
#   seq_num  : uint32
#   price_raw: uint64 (satoshis, = price_usd * 1e8)
#   size_raw : uint64 (micro-units, = size_btc * 1e6)
WIRE_FMT = "<cBIQQ"
assert struct.calcsize(WIRE_FMT) == 22

def encode_msg(msg_type: bytes, side: int, seq: int,
               price_usd: float, size_btc: float) -> bytes:
    price_raw = int(round(price_usd * 1e8))
    size_raw  = int(round(size_btc  * 1e6))
    return struct.pack(WIRE_FMT, msg_type, side, seq, price_raw, size_raw)

class CoinbaseFeed:
    def __init__(self, output_file: str | None = None, udp_target=None):
        self.output_file = output_file
        self.udp_target  = udp_target   # (host, port) for live PYNQ streaming
        self._seq = 0
        self._fh  = None

    def _next_seq(self) -> int:
        self._seq += 1
        return self._seq

    async def run(self, max_messages: int = 0):
        """Stream from Coinbase; write binary or send UDP."""
        if self.output_file:
            self._fh = open(self.output_file, "wb")

        try:
            async with websockets.connect(WS_URL) as ws:
                sub = {
                    "type": "subscribe",
                    "product_ids": [PRODUCT],
                    "channel": "level2",
                }
                await ws.send(json.dumps(sub))

                count = 0
                async for raw in ws:
                    msg = json.loads(raw)
                    packets = self._handle(msg)
                    for pkt in packets:
                        if self._fh:
                            self._fh.write(pkt)
                        if self.udp_target:
                            # Non-blocking UDP send (fire-and-forget for now)
                            pass  # filled in board/pynq/pynq_driver.py
                    count += len(packets)
                    if max_messages and count >= max_messages:
                        break
        finally:
            if self._fh:
                self._fh.flush()
                self._fh.close()

    def _handle(self, msg: dict) -> list[bytes]:
        """Parse a Coinbase WS message into binary wire packets."""
        packets = []
        if msg.get("channel") != "l2_data":
            return packets

        for event in msg.get("events", []):
            etype = event.get("type", "")
            for upd in event.get("updates", []):
                side_str = upd.get("side", "bid")
                side = 0 if side_str == "bid" else 1
                price = float(upd.get("new_quantity") and upd.get("price_level", 0)
                              or upd.get("price_level", 0))
                # Coinbase provides price_level + new_quantity
                price_usd = float(upd.get("price_level", 0))
                size_btc  = float(upd.get("new_quantity", 0))

                # Map event type to wire msg_type
                if etype in ("snapshot", "l2update") and size_btc > 0:
                    mtype = b'A' if etype == "snapshot" else b'U'
                elif size_btc == 0:
                    mtype = b'D'
                else:
                    mtype = b'U'

                pkt = encode_msg(mtype, side, self._next_seq(), price_usd, size_btc)
                packets.append(pkt)
        return packets


async def capture(output: str, n: int = 5000):
    """Capture n messages to a binary replay file."""
    feed = CoinbaseFeed(output_file=output)
    print(f"Capturing {n} messages to {output} ...")
    await feed.run(max_messages=n)
    print("Done.")


if __name__ == "__main__":
    import sys
    out = sys.argv[1] if len(sys.argv) > 1 else "python/vectors/btcusd_snapshot.bin"
    n   = int(sys.argv[2]) if len(sys.argv) > 2 else 5000
    asyncio.run(capture(out, n))
