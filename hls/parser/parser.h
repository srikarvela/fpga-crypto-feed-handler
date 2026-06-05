#pragma once
#include "msg_types.h"

// Configurable tick size (satoshis per tick). Default: 100 satoshis = $0.000001 BTC/USD.
#ifndef TICK_SIZE
#define TICK_SIZE 100ULL
#endif

// Top-level HLS function: parse a raw byte stream into normalized AXI-Stream messages.
// in_bytes : AXI-Stream of raw bytes (one byte per transfer)
// out_msgs : AXI-Stream of packed NormMsg words
void feed_parser(
    hls::stream<ap_uint<8>>& in_bytes,
    hls::stream<AxisWord>&   out_msgs
);
