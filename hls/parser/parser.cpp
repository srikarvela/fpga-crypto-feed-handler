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

        // Normalize price to ticks (integer divide)
        ap_uint<32> price_ticks = (ap_uint<32>)(price_r / TICK_SIZE);

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
