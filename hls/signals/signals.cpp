#include "signals.h"

// Exact unsigned restoring division producing exactly QBITS quotient bits.
// Precondition: num < (den << QBITS), i.e. the quotient fits in QBITS bits, and
// den > 0. Fully unrolled: one shift/compare/subtract per quotient bit, which Vitis
// HLS schedules as one pipeline stage per bit inside the II=1 loop below. Sizing
// QBITS to each signal's real quotient range (17 / 32 / 40 bits) is what replaces the
// generic 64-by-37-bit dividers (57-68 cycles each) of the first version.
template <int QBITS, int NBITS, int DBITS>
static ap_uint<QBITS> udiv_q(ap_uint<NBITS> num, ap_uint<DBITS> den) {
#pragma HLS INLINE
    ap_uint<DBITS + 1> rem = num >> QBITS;   // < den by the precondition
    ap_uint<QBITS>     q   = 0;
    for (int i = QBITS - 1; i >= 0; i--) {
#pragma HLS UNROLL
        ap_uint<DBITS + 2> rem2 = ((ap_uint<DBITS + 2>)rem << 1) | num[i];   // < 2*den
        ap_int<DBITS + 3>  diff = (ap_int<DBITS + 3>)rem2 - (ap_int<DBITS + 3>)den;
        bool neg = diff[DBITS + 2];          // one subtract; the compare is its sign bit
        rem  = neg ? (ap_uint<DBITS + 1>)rem2 : (ap_uint<DBITS + 1>)diff;
        q[i] = !neg;
    }
    return q;
}

void compute_signals(
    hls::stream<BookSnap>&  in_snap,
    hls::stream<SignalOut>& out_sig
) {
#pragma HLS INTERFACE axis port=in_snap
#pragma HLS INTERFACE axis port=out_sig
#pragma HLS INTERFACE ap_ctrl_none port=return
    // Nothing downstream ever back-pressures this block (rtl/axis_drop_fifo.v presents a
    // constant-1 TREADY), so Vivado removes the output-stall logic. A free-running
    // pipeline (style=frp) was also tried: HLS accepted it but doubled the depth to 105
    // and its valid-tracking register drove the same 1984-flip-flop input register-slice
    // clock-enable net (5.3 ns post-route), so the plain pipelined loop is kept.

    while (!in_snap.empty()) {
#pragma HLS PIPELINE II=1

        BookSnap snap = in_snap.read();

        // --- Volumes over the top-N levels (10 x 32-bit -> 36 bits) ---
        ap_uint<36> bid_vol = 0, ask_vol = 0;
        for (int i = 0; i < DEPTH; i++) {
#pragma HLS UNROLL
            if (snap.bids[i].valid) bid_vol += snap.bids[i].size;
            if (snap.asks[i].valid) ask_vol += snap.asks[i].size;
        }
        ap_uint<37> total_vol = (ap_uint<37>)bid_vol + ask_vol;

        // --- Imbalance Q16: (bidVol - askVol) * 2^16 / totalVol, truncated toward zero ---
        // |diff| <= total, so the quotient magnitude is <= 2^16: 17 quotient bits.
        bool        bid_heavy = bid_vol >= ask_vol;
        ap_uint<36> diff      = bid_heavy ? (ap_uint<36>)(bid_vol - ask_vol) : (ap_uint<36>)(ask_vol - bid_vol);
        ap_uint<53> imb_num   = (ap_uint<53>)diff << 16;
        ap_uint<17> imb_q     = (total_vol == 0) ? (ap_uint<17>)0 : udiv_q<17, 53, 37>(imb_num, total_vol);
        ap_int<32>  imbalance = bid_heavy ? (ap_int<32>)imb_q : (ap_int<32>)(-(ap_int<32>)imb_q);

        // --- Microprice: (best_bid*ask_vol + best_ask*bid_vol) / total_vol ---
        // Lies between best_bid and best_ask, so the quotient fits in 32 bits.
        bool best_bid_valid = snap.bids[0].valid;
        bool best_ask_valid = snap.asks[0].valid;
        ap_uint<68> mp_b = (ap_uint<68>)snap.bids[0].price * ask_vol;
#pragma HLS BIND_OP variable=mp_b op=mul impl=dsp latency=4
        ap_uint<68> mp_a = (ap_uint<68>)snap.asks[0].price * bid_vol;
#pragma HLS BIND_OP variable=mp_a op=mul impl=dsp latency=4
        ap_uint<69> mp_num = (ap_uint<69>)mp_b + (ap_uint<69>)mp_a;
        ap_uint<32> microprice = 0;
        if (best_bid_valid && best_ask_valid && total_vol > 0)
            microprice = udiv_q<32, 69, 37>(mp_num, total_vol);

        // --- Spread ---
        ap_uint<32> spread = 0;
        if (best_bid_valid && best_ask_valid && snap.asks[0].price >= snap.bids[0].price)
            spread = snap.asks[0].price - snap.bids[0].price;

        // --- VWAP Q8 per side: (sum(price*size) << 8) / vol ---
        // sum(price*size) < 2^32 * vol, so the quotient is < 2^40: 40 quotient bits, then
        // the same 32-bit truncation as the SignalOut field.
        ap_uint<68> bid_ps = 0, ask_ps = 0;
        for (int i = 0; i < DEPTH; i++) {
#pragma HLS UNROLL
            ap_uint<64> pb = (ap_uint<64>)snap.bids[i].price * snap.bids[i].size;
#pragma HLS BIND_OP variable=pb op=mul impl=dsp latency=4
            ap_uint<64> pa = (ap_uint<64>)snap.asks[i].price * snap.asks[i].size;
#pragma HLS BIND_OP variable=pa op=mul impl=dsp latency=4
            if (snap.bids[i].valid) bid_ps += pb;
            if (snap.asks[i].valid) ask_ps += pa;
        }
        ap_uint<76> vb_num = (ap_uint<76>)bid_ps << 8;
        ap_uint<76> va_num = (ap_uint<76>)ask_ps << 8;
        ap_int<32> vwap_bid = (bid_vol > 0) ? (ap_int<32>)udiv_q<40, 76, 36>(vb_num, bid_vol) : (ap_int<32>)0;
        ap_int<32> vwap_ask = (ask_vol > 0) ? (ap_int<32>)udiv_q<40, 76, 36>(va_num, ask_vol) : (ap_int<32>)0;

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
