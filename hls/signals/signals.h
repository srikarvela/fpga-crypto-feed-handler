#pragma once
#include <ap_fixed.h>
#include <ap_int.h>
#include <hls_stream.h>

// Snapshot word from the Chisel order book (passed back via AXI-Lite registers or DMA)
static const int DEPTH = 10;

struct LevelHW {
    ap_uint<32> price;
    ap_uint<32> size;
    ap_uint<1>  valid;
};

struct BookSnap {
    LevelHW bids[DEPTH];
    LevelHW asks[DEPTH];
    ap_int<32>  imbalance;  // Q16 from Chisel (passthrough, recomputed here for reference)
    ap_uint<32> midprice;
    ap_uint<32> seq_num;
};

// Extended signal output
struct SignalOut {
    ap_int<32>  imbalance;     // (bidVol-askVol)/(bidVol+askVol)*2^16, Q16
    ap_uint<32> microprice;    // size-weighted midprice in ticks
    ap_uint<32> spread;        // best_ask - best_bid in ticks (0 if book empty)
    ap_int<32>  vwap_bid;      // volume-weighted avg price, bid side, Q8
    ap_int<32>  vwap_ask;      // volume-weighted avg price, ask side, Q8
    ap_uint<32> seq_num;
    ap_uint<1>  valid;
};

void compute_signals(
    hls::stream<BookSnap>&  in_snap,
    hls::stream<SignalOut>& out_sig
);
