#include "signals.h"
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <cstdint>

// Plain-integer reference for every signal (exact division on wide integers), used to
// check the custom quotient-sized dividers bit-for-bit on random books.
static void reference(const BookSnap& snap, SignalOut& r) {
    unsigned __int128 bid_vol = 0, ask_vol = 0, bid_ps = 0, ask_ps = 0;
    for (int i = 0; i < DEPTH; i++) {
        if (snap.bids[i].valid) { bid_vol += (uint64_t)snap.bids[i].size; bid_ps += (unsigned __int128)(uint64_t)snap.bids[i].price * (uint64_t)snap.bids[i].size; }
        if (snap.asks[i].valid) { ask_vol += (uint64_t)snap.asks[i].size; ask_ps += (unsigned __int128)(uint64_t)snap.asks[i].price * (uint64_t)snap.asks[i].size; }
    }
    unsigned __int128 total = bid_vol + ask_vol;
    __int128 imb = 0;
    if (total) imb = (((__int128)bid_vol - (__int128)ask_vol) << 16) / (__int128)total;   // C++ truncates toward zero
    r.imbalance = (int32_t)imb;
    r.microprice = 0;
    if (snap.bids[0].valid && snap.asks[0].valid && total)
        r.microprice = (uint32_t)(((unsigned __int128)(uint64_t)snap.bids[0].price * ask_vol + (unsigned __int128)(uint64_t)snap.asks[0].price * bid_vol) / total);
    r.spread = 0;
    if (snap.bids[0].valid && snap.asks[0].valid && (uint64_t)snap.asks[0].price >= (uint64_t)snap.bids[0].price)
        r.spread = (uint32_t)((uint64_t)snap.asks[0].price - (uint64_t)snap.bids[0].price);
    r.vwap_bid = bid_vol ? (int32_t)(uint32_t)((bid_ps << 8) / bid_vol) : 0;
    r.vwap_ask = ask_vol ? (int32_t)(uint32_t)((ask_ps << 8) / ask_vol) : 0;
    r.seq_num = snap.seq_num;
    r.valid = 1;
}

static int check(const SignalOut& s, const SignalOut& r, int tag) {
    int bad = 0;
    if (s.imbalance  != r.imbalance)  { printf("[%d] imbalance  hw=%d ref=%d\n", tag, (int)s.imbalance, (int)r.imbalance); bad++; }
    if (s.microprice != r.microprice) { printf("[%d] microprice hw=%u ref=%u\n", tag, (unsigned)s.microprice, (unsigned)r.microprice); bad++; }
    if (s.spread     != r.spread)     { printf("[%d] spread     hw=%u ref=%u\n", tag, (unsigned)s.spread, (unsigned)r.spread); bad++; }
    if (s.vwap_bid   != r.vwap_bid)   { printf("[%d] vwap_bid   hw=%d ref=%d\n", tag, (int)s.vwap_bid, (int)r.vwap_bid); bad++; }
    if (s.vwap_ask   != r.vwap_ask)   { printf("[%d] vwap_ask   hw=%d ref=%d\n", tag, (int)s.vwap_ask, (int)r.vwap_ask); bad++; }
    if (s.seq_num    != r.seq_num)    { printf("[%d] seq_num\n", tag); bad++; }
    return bad;
}

static uint64_t rng_state = 0x9E3779B97F4A7C15ULL;
static uint64_t rnd() { rng_state ^= rng_state << 13; rng_state ^= rng_state >> 7; rng_state ^= rng_state << 17; return rng_state; }

int main() {
    hls::stream<BookSnap>  in_snap;
    hls::stream<SignalOut> out_sig;
    int errors = 0;

    // ---- Directed case (the original testbench) ----
    BookSnap snap = {};
    snap.seq_num = 42;
    snap.bids[0] = {200, 100, 1};
    snap.bids[1] = {199,  50, 1};
    for (int i = 2; i < DEPTH; i++) snap.bids[i].valid = 0;
    snap.asks[0] = {201, 30, 1};
    snap.asks[1] = {202, 20, 1};
    for (int i = 2; i < DEPTH; i++) snap.asks[i].valid = 0;

    in_snap.write(snap);
    compute_signals(in_snap, out_sig);
    assert(!out_sig.empty());
    SignalOut s = out_sig.read();
    // bid_vol=150, ask_vol=50, total=200: imbalance = 100/200 * 65536 = 32768
    printf("imbalance = %d (expected 32768)\n", (int)s.imbalance);
    assert(s.imbalance == 32768);
    printf("spread = %u (expected 1)\n", (unsigned)s.spread);
    assert(s.spread == 1);
    // microprice = (200*50 + 201*150)/200 = 40150/200 = 200
    printf("microprice = %u (expected 200)\n", (unsigned)s.microprice);
    assert(s.microprice == 200);
    // vwap_bid Q8 = (200*100 + 199*50)*256/150 = 29950*256/150 = 51114 (truncated)
    printf("vwap_bid = %d (expected 51114)\n", (int)s.vwap_bid);
    assert(s.vwap_bid == 51114);
    SignalOut ref; reference(snap, ref);
    errors += check(s, ref, -1);

    // ---- Edge cases: empty book, one side only, equal volumes, max-size levels ----
    BookSnap edge[4] = {};
    edge[0].seq_num = 1;                                             // empty
    edge[1].seq_num = 2; edge[1].bids[0] = {500, 7, 1};              // bids only
    edge[2].seq_num = 3; edge[2].bids[0] = {100, 10, 1}; edge[2].asks[0] = {101, 10, 1};   // equal volumes
    edge[3].seq_num = 4;
    for (int i = 0; i < DEPTH; i++) { edge[3].bids[i] = {0xFFFFFFFFu - i, 0xFFFFFFFFu, 1}; edge[3].asks[i] = {0xFFFFFFFFu, 0xFFFFFFFFu, 1}; }
    for (int k = 0; k < 4; k++) {
        in_snap.write(edge[k]);
        compute_signals(in_snap, out_sig);
        s = out_sig.read();
        reference(edge[k], ref);
        errors += check(s, ref, 100 + k);
    }

    // ---- Random books, bit-exact against the wide-integer reference ----
    const int N = 400;
    for (int n = 0; n < N; n++) {
        BookSnap b = {};
        b.seq_num = 1000 + n;
        int nb = rnd() % (DEPTH + 1), na = rnd() % (DEPTH + 1);
        uint32_t pmask = (n % 3 == 0) ? 0xFFFFFFFFu : (n % 3 == 1) ? 0x0FFFFFFFu : 0x000FFFFFu;
        uint32_t smask = (n % 4 == 0) ? 0xFFFFFFFFu : (n % 4 == 1) ? 0x00FFFFFFu : (n % 4 == 2) ? 0x0000FFFFu : 0x000000FFu;
        uint32_t bid0 = rnd() & pmask, ask0 = bid0 + (uint32_t)(rnd() & 0xFFFF);
        for (int i = 0; i < nb; i++) b.bids[i] = {(ap_uint<32>)(bid0 - i * (uint32_t)(1 + rnd() % 3)), (ap_uint<32>)((rnd() & smask) | 1), 1};
        for (int i = 0; i < na; i++) b.asks[i] = {(ap_uint<32>)(ask0 + i * (uint32_t)(1 + rnd() % 3)), (ap_uint<32>)((rnd() & smask) | 1), 1};
        in_snap.write(b);
        compute_signals(in_snap, out_sig);
        s = out_sig.read();
        reference(b, ref);
        errors += check(s, ref, n);
    }

    if (errors) { printf("signals_tb FAILED: %d mismatches\n", errors); return 1; }
    printf("signals_tb PASSED (directed + 4 edge + %d random books, bit-exact)\n", N);
    return 0;
}
