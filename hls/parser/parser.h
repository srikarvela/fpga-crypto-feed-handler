#pragma once
#include "msg_types.h"

// Configurable tick size (satoshis per tick). Default: 100 satoshis = $0.000001 BTC/USD.
#ifndef TICK_SIZE
#define TICK_SIZE 100ULL
#endif

// price_raw / TICK_SIZE for TICK_SIZE == 100 as a multiply by a 65-bit reciprocal
// (Granlund-Montgomery "add-back" form, exact for every 64-bit input) so that the
// divide is a deeply pipelined DSP multiply instead of a 103-bit combinational one.
ap_uint<64> parser_div100(ap_uint<64> x);

// Top-level HLS function: parse a raw byte stream into normalized AXI-Stream messages.
// in_bytes : AXI-Stream of raw bytes (one byte per transfer)
// out_msgs : AXI-Stream of packed NormMsg words
void feed_parser(
    hls::stream<ap_uint<8>>& in_bytes,
    hls::stream<AxisWord>&   out_msgs
);
