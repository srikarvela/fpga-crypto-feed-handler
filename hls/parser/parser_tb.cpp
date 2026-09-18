#include "parser.h"
#include <cassert>
#include <cstdio>
#include <cstring>
#include <cstdint>

// Pack a RawMsg into the 22-byte wire format (little-endian)
static void encode_msg(ap_uint<8>* buf, char type, uint8_t side,
                       uint32_t seq, uint64_t price_r, uint64_t size_r) {
    buf[0] = (ap_uint<8>)type;
    buf[1] = side;
    memcpy(buf + 2,  &seq,     4);
    memcpy(buf + 6,  &price_r, 8);
    memcpy(buf + 14, &size_r,  8);
}

int main() {
    hls::stream<ap_uint<8>> in_bytes;
    hls::stream<AxisWord>   out_msgs;

    // Message 1: Add bid at $30,000.50 (3000050000 satoshis), size 1.5 BTC (1500000 micro)
    // With TICK_SIZE=100: price_ticks = 3000050000/100 = 30000500
    ap_uint<8> buf[RAW_MSG_BYTES];
    encode_msg(buf, 'A', 0, 1, 3000050000ULL, 1500000ULL);
    for (int i = 0; i < RAW_MSG_BYTES; i++) in_bytes.write(buf[i]);

    // Message 2: Add ask at $30,001.00, size 0.5 BTC
    encode_msg(buf, 'A', 1, 2, 3000100000ULL, 500000ULL);
    for (int i = 0; i < RAW_MSG_BYTES; i++) in_bytes.write(buf[i]);

    // Message 3: Delete bid at $30,000.50
    encode_msg(buf, 'D', 0, 3, 3000050000ULL, 0ULL);
    for (int i = 0; i < RAW_MSG_BYTES; i++) in_bytes.write(buf[i]);

    // Message 4: Unknown type — should be dropped
    encode_msg(buf, 'X', 0, 4, 1234ULL, 100ULL);
    for (int i = 0; i < RAW_MSG_BYTES; i++) in_bytes.write(buf[i]);

    feed_parser(in_bytes, out_msgs);

    // Expect 3 output messages (msg 4 dropped)
    assert(out_msgs.size() == 3 && "Expected 3 output messages");

    // Verify message 1
    AxisWord w = out_msgs.read();
    ap_uint<32> price   = w.range(31, 0);
    ap_uint<32> size    = w.range(63, 32);
    ap_uint<1>  side    = w.range(64, 64);
    ap_uint<32> seq_out = w.range(96, 65);
    assert(price == 30000500 && "msg1 price mismatch");
    assert(size  == 1500000  && "msg1 size mismatch");
    assert(side  == 0        && "msg1 side mismatch");
    assert(seq_out == 1      && "msg1 seq mismatch");

    // Verify message 3 (delete): size should be 0
    out_msgs.read(); // skip msg2
    w = out_msgs.read();
    size = w.range(63, 32);
    assert(size == 0 && "delete msg should have size=0");

    // The reciprocal-multiply divide must equal '/' for every input: boundaries + random
    {
        uint64_t xs[] = {0, 1, 99, 100, 101, 199, 200, 0xFFFFFFFFULL, 0x100000000ULL, 0x7FFFFFFFFFFFFFFFULL,
                         0x8000000000000000ULL, 0xFFFFFFFFFFFFFFFFULL, 0xFFFFFFFFFFFFFF9CULL, 0xFFFFFFFFFFFFFF9BULL};
        for (uint64_t x : xs) assert((uint64_t)parser_div100(x) == x / 100);
        uint64_t st = 0x2545F4914F6CDD1DULL;
        for (int i = 0; i < 200000; i++) {
            st ^= st << 13; st ^= st >> 7; st ^= st << 17;
            uint64_t x = (i % 2) ? st : (st >> (i % 60));
            if ((uint64_t)parser_div100(x) != x / 100) { printf("div100 mismatch at %llu\n", (unsigned long long)x); return 1; }
        }
    }
    printf("parser_tb PASSED\n");
    return 0;
}
