#include "parser.h"

// Receive exactly `n` bytes from the stream into a local buffer.
static void recv_bytes(hls::stream<ap_uint<8>>& s, ap_uint<8>* buf, int n) {
#pragma HLS INLINE
    for (int i = 0; i < n; i++) {
#pragma HLS PIPELINE II=1
        buf[i] = s.read();
    }
}

// Reconstruct a little-endian 32-bit word from 4 bytes.
static ap_uint<32> le32(const ap_uint<8>* buf) {
#pragma HLS INLINE
    return (ap_uint<32>)buf[0]       |
           ((ap_uint<32>)buf[1] << 8) |
           ((ap_uint<32>)buf[2] << 16)|
           ((ap_uint<32>)buf[3] << 24);
}

// Reconstruct a little-endian 64-bit word from 8 bytes.
static ap_uint<64> le64(const ap_uint<8>* buf) {
#pragma HLS INLINE
    ap_uint<64> lo = le32(buf);
    ap_uint<64> hi = le32(buf + 4);
    return lo | (hi << 32);
}

// x / 100 for any 64-bit x:  t = mulhi(x, M'),  q = (t + ((x - t) >> 1)) >> 6,
// with M' = ceil(2^71 / 100) - 2^64 = 0x47AE147AE147AE15 (checked exhaustively at the
// 64-bit boundaries and on 3.5e5 random inputs in the Python derivation; the C testbench
// re-checks it against '/' on random inputs, and co-simulation checks the RTL).
ap_uint<64> parser_div100(ap_uint<64> x) {
#pragma HLS INLINE off
#pragma HLS PIPELINE II=1
    // mulhi(x, M') from four 32x32 partial products (each one DSP48E1 cascade with
    // its own pipeline registers) and 64-bit adds in separate stages, instead of
    // one 64x64 multiply that Vitis HLS would implement as a 103-bit combinational op.
    const ap_uint<32> mh = 0x47AE147AUL, ml = 0xE147AE15UL;   // M' = {mh, ml}
    ap_uint<32> xh = x.range(63, 32), xl = x.range(31, 0);
    ap_uint<64> hh = xh * mh;
#pragma HLS BIND_OP variable=hh op=mul impl=dsp latency=4
    ap_uint<64> hl = xh * ml;
#pragma HLS BIND_OP variable=hl op=mul impl=dsp latency=4
    ap_uint<64> lh = xl * mh;
#pragma HLS BIND_OP variable=lh op=mul impl=dsp latency=4
    ap_uint<64> ll = xl * ml;
#pragma HLS BIND_OP variable=ll op=mul impl=dsp latency=4
    ap_uint<66> mid = (ap_uint<66>)hl + (ap_uint<66>)lh + (ap_uint<66>)(ll >> 32);   // exact, < 2^66
    ap_uint<64> t   = hh + (ap_uint<64>)(mid >> 32);                                // = (x * M') >> 64
    ap_uint<64> q   = (t + ((x - t) >> 1)) >> 6;
    return q;
}

// feed_parser: consume raw binary messages (22 bytes each), emit NormMsg words.
// Runs as a dataflow pipeline: one message per II=22 cycles.
void feed_parser(
    hls::stream<ap_uint<8>>& in_bytes,
    hls::stream<AxisWord>&   out_msgs
) {
#pragma HLS INTERFACE axis port=in_bytes
#pragma HLS INTERFACE axis port=out_msgs
#pragma HLS INTERFACE ap_ctrl_none port=return

    ap_uint<8> buf[RAW_MSG_BYTES];
#pragma HLS ARRAY_PARTITION variable=buf complete

    // Process messages until the input stream is empty.
    while (!in_bytes.empty()) {
#pragma HLS PIPELINE II=22

        recv_bytes(in_bytes, buf, RAW_MSG_BYTES);

        ap_uint<8>  msg_type = buf[0];
        ap_uint<8>  side_raw = buf[1];
        ap_uint<32> seq      = le32(buf + 2);
        ap_uint<64> price_r  = le64(buf + 6);
        ap_uint<64> size_r   = le64(buf + 14);

        // Normalize price to ticks (integer divide by the compile-time TICK_SIZE)
#if TICK_SIZE == 100ULL
        ap_uint<32> price_ticks = (ap_uint<32>)parser_div100(price_r);
#else
        ap_uint<32> price_ticks = (ap_uint<32>)(price_r / TICK_SIZE);
#endif

        // Delete messages (type 'D') → size = 0 signals deletion to the order book
        ap_uint<32> size_norm = (msg_type == 'D') ? (ap_uint<32>)0 : (ap_uint<32>)size_r;

        // Filter: only emit add, update, delete; drop unknown types
        if (msg_type == 'A' || msg_type == 'U' || msg_type == 'D') {
            NormMsg m;
            m.price   = price_ticks;
            m.size    = size_norm;
            m.side    = side_raw & 1;
            m.seq_num = seq;
            out_msgs.write(pack_norm(m));
        }
    }
}
