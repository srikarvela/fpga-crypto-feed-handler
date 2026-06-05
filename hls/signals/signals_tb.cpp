#include "signals.h"
#include <cassert>
#include <cstdio>
#include <cmath>

int main() {
    hls::stream<BookSnap>  in_snap;
    hls::stream<SignalOut> out_sig;

    BookSnap snap = {};
    snap.seq_num = 42;

    // Bids: 100@200ticks, 50@199ticks
    snap.bids[0] = {200, 100, 1};
    snap.bids[1] = {199,  50, 1};
    for (int i = 2; i < DEPTH; i++) snap.bids[i].valid = 0;

    // Asks: 30@201ticks, 20@202ticks
    snap.asks[0] = {201, 30, 1};
    snap.asks[1] = {202, 20, 1};
    for (int i = 2; i < DEPTH; i++) snap.asks[i].valid = 0;

    in_snap.write(snap);
    compute_signals(in_snap, out_sig);

    assert(!out_sig.empty());
    SignalOut s = out_sig.read();

    // bid_vol=150, ask_vol=50, total=200
    // imbalance = (150-50)/200 * 2^16 = 100/200 * 65536 = 32768
    printf("imbalance = %d (expected ~32768)\n", (int)s.imbalance);
    assert(s.imbalance > 0 && "bid-heavy book should have positive imbalance");

    // spread = 201-200 = 1 tick
    printf("spread = %u (expected 1)\n", (unsigned)s.spread);
    assert(s.spread == 1);

    // microprice = (200*50 + 201*150)/200 = (10000+30150)/200 = 40150/200 = 200.75 → 200 in integer
    printf("microprice = %u (expected 200)\n", (unsigned)s.microprice);
    assert(s.microprice == 200);

    // VWAP bid Q8: (200*100 + 199*50)/150 * 256 = (20000+9950)/150*256
    // = 29950/150*256 = 199.667*256 = 51115
    printf("vwap_bid = %d\n", (int)s.vwap_bid);
    assert(s.vwap_bid > 0);

    printf("signals_tb PASSED\n");
    return 0;
}
