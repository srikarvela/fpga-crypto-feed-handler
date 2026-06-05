#include "signals.h"

void compute_signals(
    hls::stream<BookSnap>&  in_snap,
    hls::stream<SignalOut>& out_sig
) {
#pragma HLS INTERFACE axis port=in_snap
#pragma HLS INTERFACE axis port=out_sig
#pragma HLS INTERFACE ap_ctrl_none port=return

    while (!in_snap.empty()) {
#pragma HLS PIPELINE II=1

        BookSnap snap = in_snap.read();

        // --- Imbalance (recompute from levels for verification) ---
        ap_uint<64> bid_vol = 0, ask_vol = 0;
        for (int i = 0; i < DEPTH; i++) {
#pragma HLS UNROLL
            if (snap.bids[i].valid) bid_vol += snap.bids[i].size;
            if (snap.asks[i].valid) ask_vol += snap.asks[i].size;
        }
        ap_uint<64> total_vol = bid_vol + ask_vol;
        ap_int<32>  imbalance = (total_vol == 0) ? ap_int<32>(0)
            : ap_int<32>(((ap_int<64>)(bid_vol - ask_vol) << 16) / (ap_int<64>)total_vol);

        // --- Microprice: size-weighted midprice ---
        // microprice = (best_bid*ask_vol + best_ask*bid_vol) / total_vol
        ap_uint<32> microprice = 0;
        bool best_bid_valid = snap.bids[0].valid;
        bool best_ask_valid = snap.asks[0].valid;
        if (best_bid_valid && best_ask_valid && total_vol > 0) {
            ap_uint<64> num = (ap_uint<64>)snap.bids[0].price * ask_vol
                            + (ap_uint<64>)snap.asks[0].price * bid_vol;
            microprice = (ap_uint<32>)(num / total_vol);
        }

        // --- Spread ---
        ap_uint<32> spread = 0;
        if (best_bid_valid && best_ask_valid && snap.asks[0].price >= snap.bids[0].price)
            spread = snap.asks[0].price - snap.bids[0].price;

        // --- VWAP (N-level, integer, Q8 fixed-point) ---
        ap_int<64> vwap_bid_num = 0, vwap_ask_num = 0;
        for (int i = 0; i < DEPTH; i++) {
#pragma HLS UNROLL
            if (snap.bids[i].valid)
                vwap_bid_num += (ap_int<64>)snap.bids[i].price * snap.bids[i].size;
            if (snap.asks[i].valid)
                vwap_ask_num += (ap_int<64>)snap.asks[i].price * snap.asks[i].size;
        }
        ap_int<32> vwap_bid = (bid_vol > 0)
            ? ap_int<32>((vwap_bid_num << 8) / (ap_int<64>)bid_vol) : ap_int<32>(0);
        ap_int<32> vwap_ask = (ask_vol > 0)
            ? ap_int<32>((vwap_ask_num << 8) / (ap_int<64>)ask_vol) : ap_int<32>(0);

        SignalOut s;
        s.imbalance  = imbalance;
        s.microprice = microprice;
        s.spread     = spread;
        s.vwap_bid   = vwap_bid;
        s.vwap_ask   = vwap_ask;
        s.seq_num    = snap.seq_num;
        s.valid      = 1;
        out_sig.write(s);
    }
}
