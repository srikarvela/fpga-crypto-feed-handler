#pragma once
#include <ap_int.h>
#include <hls_stream.h>

// Raw wire format: Coinbase-style L2 update, packed binary
// Matches the Python feed adapter's struct.pack layout
struct RawMsg {
    ap_uint<8>  msg_type;   // 'A'=add, 'U'=update, 'D'=delete
    ap_uint<8>  side;       // 0=bid, 1=ask
    ap_uint<32> seq_num;
    ap_uint<64> price_raw;  // price in satoshis (1e8 units)
    ap_uint<64> size_raw;   // size in micro-units (1e6)
};
static const int RAW_MSG_BYTES = 1+1+4+8+8; // 22 bytes

// Normalized message: fixed-point ticks
// price_ticks = price_raw / TICK_SIZE (configurable at synthesis time)
// size_units  = size_raw  (already in 1e6)
struct NormMsg {
    ap_uint<32> price;    // price in ticks
    ap_uint<32> size;     // quantity (0 = delete)
    ap_uint<1>  side;
    ap_uint<32> seq_num;
};

// AXI-Stream word: carries one NormMsg
// Layout: {seq_num[31:0], side[0], size[31:0], price[31:0]} = 97 bits → padded to 128
typedef ap_uint<128> AxisWord;

inline AxisWord pack_norm(const NormMsg& m) {
    AxisWord w = 0;
    w.range(31,  0)  = m.price;
    w.range(63,  32) = m.size;
    w.range(64,  64) = m.side;
    w.range(96,  65) = m.seq_num;
    return w;
}
