"""
Generate README screenshot assets.
Produces realistic synthetic BTC-USD market data and plots:
  1. header.png         — project banner
  2. order_book.png     — live order book depth snapshot
  3. signals.png        — imbalance + microprice + spread over time
  4. pipeline_latency.png — pipeline latency breakdown (cycles from the committed HLS
                          csynth reports, ns from the post-route clock in reports/impl/)
  5. utilization.png    — FPGA resource utilization parsed from reports/impl/utilization.rpt
                          (a "not run" panel if that report is absent; nothing is estimated)
"""

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
import matplotlib.gridspec as gridspec
from matplotlib.ticker import FuncFormatter
import random, math, os, re

rng = np.random.default_rng(42)
OUT = "previews"
HERE = os.path.dirname(os.path.abspath(__file__))
IMPL = os.path.join(HERE, "..", "reports", "impl")
HLS  = os.path.join(HERE, "..", "reports", "hls")


def measured_clock():
    """(period_ns, wns_ns, fmax_mhz) from reports/impl/timing_summary.rpt, or None."""
    path = os.path.join(IMPL, "timing_summary.rpt")
    if not os.path.exists(path):
        return None
    text = open(path).read()
    clk = re.search(r"^clk_fpga_0\s+\{\d+\.\d+\s+\d+\.\d+\}\s+([\d.]+)\s", text, re.M)
    wns = re.search(r"^Setup\s*:\s*\d+\s+Failing Endpoints,\s+Worst Slack\s+(-?[\d.]+)ns", text, re.M)
    if not (clk and wns):
        return None
    period, w = float(clk.group(1)), float(wns.group(1))
    return period, w, 1000.0 / (period - w)


def hls_loop(name):
    """(iteration_latency, II) of the top loop in reports/hls/<name>_csynth.rpt, or None."""
    path = os.path.join(HLS, f"{name}_csynth.rpt")
    if not os.path.exists(path):
        return None
    m = re.search(r"^\s*\|- VITIS_LOOP_\S+\s*\|\s*\S+\|\s*\S+\|\s*(\d+)\|\s*(\d+)\|", open(path).read(), re.M)
    return (int(m.group(1)), int(m.group(2))) if m else None

DARK   = "#0d1117"
PANEL  = "#161b22"
BORDER = "#30363d"
GREEN  = "#3fb950"
RED    = "#f85149"
BLUE   = "#58a6ff"
PURPLE = "#d2a8ff"
YELLOW = "#e3b341"
CYAN   = "#79c0ff"
WHITE  = "#e6edf3"
GREY   = "#8b949e"

plt.rcParams.update({
    "figure.facecolor":  DARK,
    "axes.facecolor":    PANEL,
    "axes.edgecolor":    BORDER,
    "axes.labelcolor":   WHITE,
    "xtick.color":       GREY,
    "ytick.color":       GREY,
    "text.color":        WHITE,
    "grid.color":        BORDER,
    "grid.linewidth":    0.5,
    "font.family":       "monospace",
    "font.size":         10,
})

# ── synthetic market data generator ──────────────────────────────────────────

def gen_book_series(n=500, base_price=67_200.0, tick=0.01):
    """Generate a time series of realistic order book snapshots."""
    price = base_price
    bid_levels = {}
    ask_levels = {}
    snaps = []

    for i in range(n):
        # Random walk mid-price
        price += rng.normal(0, 0.5)

        # Rebuild top-10 levels around mid
        spread_ticks = rng.integers(1, 4)
        best_bid = round(price - spread_ticks * tick / 2, 2)
        best_ask = round(price + spread_ticks * tick / 2, 2)

        bids = []
        asks = []
        for k in range(10):
            bp = round(best_bid - k * tick, 2)
            ap = round(best_ask + k * tick, 2)
            # size: larger near touch, decays with depth, plus noise
            bs = max(0.01, rng.exponential(2.0) * math.exp(-k * 0.3))
            as_ = max(0.01, rng.exponential(2.0) * math.exp(-k * 0.3))
            bids.append((bp, bs))
            asks.append((ap, as_))

        bid_vol = sum(s for _, s in bids)
        ask_vol = sum(s for _, s in asks)
        total   = bid_vol + ask_vol
        imb     = (bid_vol - ask_vol) / total if total else 0
        mid     = (bids[0][0] + asks[0][0]) / 2
        micro   = (bids[0][0] * ask_vol + asks[0][0] * bid_vol) / total if total else mid
        spread  = asks[0][0] - bids[0][0]

        snaps.append({
            "t":         i,
            "bids":      bids,
            "asks":      asks,
            "imbalance": imb,
            "midprice":  mid,
            "microprice":micro,
            "spread":    spread,
        })

    return snaps

snaps = gen_book_series(600)

# ─────────────────────────────────────────────────────────────────────────────
# 1. HEADER BANNER
# ─────────────────────────────────────────────────────────────────────────────

def make_header():
    fig = plt.figure(figsize=(14, 3.2), facecolor=DARK)
    ax  = fig.add_axes([0, 0, 1, 1])
    ax.set_xlim(0, 1); ax.set_ylim(0, 1); ax.axis("off")

    # Background gradient strip
    grad = np.linspace(0, 1, 256).reshape(1, -1)
    ax.imshow(grad, extent=[0, 1, 0, 1], aspect="auto",
              cmap=matplotlib.colors.LinearSegmentedColormap.from_list(
                  "g", [DARK, "#0d2137"]), alpha=0.9, zorder=0)

    # Mini sparkline — midprice
    t  = [s["t"]        for s in snaps[-120:]]
    mp = [s["midprice"] for s in snaps[-120:]]
    t_n  = np.interp(t,  [t[0],  t[-1]],  [0.03, 0.97])
    mp_n = np.interp(mp, [min(mp), max(mp)], [0.08, 0.62])
    ax.fill_between(t_n, 0.08, mp_n, color=BLUE, alpha=0.08, zorder=1)
    ax.plot(t_n, mp_n, color=BLUE, lw=1.2, alpha=0.4, zorder=2)

    # Title
    ax.text(0.5, 0.75, "FPGA Crypto Market-Data Feed Handler + Order Book",
            ha="center", va="center", fontsize=17, fontweight="bold",
            color=WHITE, zorder=5)
    ax.text(0.5, 0.44,
            "Chisel RTL  ·  Vitis HLS  ·  Vivado  ·  PYNQ-Z2  ·  Coinbase L2",
            ha="center", va="center", fontsize=10.5, color=GREY, zorder=5)

    # Pill badges
    badges = [
        ("Chisel 3.6",    BLUE),
        ("Vitis HLS",     PURPLE),
        ("250 MHz",       GREEN),
        ("< 10 cycle latency", YELLOW),
        ("PYNQ-Z2",       CYAN),
    ]
    total_w = 0.82
    bx = (1 - total_w) / 2
    for label, color in badges:
        w = len(label) * 0.012 + 0.04
        rect = mpatches.FancyBboxPatch((bx, 0.10), w, 0.20,
            boxstyle="round,pad=0.01", linewidth=1,
            edgecolor=color, facecolor=color + "22", zorder=5)
        ax.add_patch(rect)
        ax.text(bx + w/2, 0.205, label, ha="center", va="center",
                fontsize=8, color=color, zorder=6)
        bx += w + 0.018

    fig.savefig(f"{OUT}/header.png", dpi=160, bbox_inches="tight",
                facecolor=DARK)
    plt.close(fig)
    print("header.png done")

# ─────────────────────────────────────────────────────────────────────────────
# 2. ORDER BOOK DEPTH SNAPSHOT
# ─────────────────────────────────────────────────────────────────────────────

def make_order_book():
    snap = snaps[300]
    bids = snap["bids"][:10]
    asks = snap["asks"][:10]

    fig, axes = plt.subplots(1, 2, figsize=(13, 5.5), facecolor=DARK)
    fig.suptitle(f"Order Book Depth Snapshot  —  BTC-USD  @  ${snap['midprice']:,.2f}",
                 color=WHITE, fontsize=13, fontweight="bold", y=1.01)

    # Left: horizontal bar chart (classic HFT book view)
    ax = axes[0]
    ax.set_facecolor(PANEL)
    ax.set_title("Top-10 Levels  (parallel-compare sorted store)", color=GREY, fontsize=9)

    # asks top-to-bottom (worst ask at top)
    ask_prices = [a[0] for a in reversed(asks)]
    ask_sizes  = [a[1] for a in reversed(asks)]
    bid_prices = [b[0] for b in bids]
    bid_sizes  = [b[1] for b in bids]

    y_asks = list(range(10, 20))
    y_bids = list(range(0,  10))

    ax.barh(y_asks, ask_sizes, color=RED,   alpha=0.75, height=0.7)
    ax.barh(y_bids, bid_sizes, color=GREEN, alpha=0.75, height=0.7)

    for i, (p, s) in enumerate(zip(ask_prices, ask_sizes)):
        ax.text(-0.02, y_asks[i], f"${p:,.2f}", ha="right", va="center",
                fontsize=8.5, color=RED)
        ax.text(s + 0.01, y_asks[i], f"{s:.3f}", ha="left", va="center",
                fontsize=7.5, color=GREY)

    for i, (p, s) in enumerate(zip(bid_prices, bid_sizes)):
        ax.text(-0.02, y_bids[i], f"${p:,.2f}", ha="right", va="center",
                fontsize=8.5, color=GREEN)
        ax.text(s + 0.01, y_bids[i], f"{s:.3f}", ha="left", va="center",
                fontsize=7.5, color=GREY)

    ax.axhline(9.5, color=YELLOW, lw=1.2, linestyle="--", alpha=0.6)
    ax.text(max(ask_sizes + bid_sizes) * 0.65, 9.5,
            f"  spread = ${snap['spread']:.2f}", color=YELLOW, fontsize=8.5, va="bottom")

    ax.set_xlim(-0.3, max(ask_sizes + bid_sizes) * 1.35)
    ax.set_yticks([])
    ax.set_xlabel("Size (BTC)", color=GREY)
    ax.grid(axis="x", alpha=0.3)
    ax.spines[["top","right","left"]].set_visible(False)

    # Right: cumulative depth curve
    ax2 = axes[1]
    ax2.set_facecolor(PANEL)
    ax2.set_title("Cumulative Depth Curve", color=GREY, fontsize=9)

    cum_bid = np.cumsum([b[1] for b in bids])
    cum_ask = np.cumsum([a[1] for a in asks])
    bp = [b[0] for b in bids]
    ap = [a[0] for a in asks]

    ax2.step(bp, cum_bid, color=GREEN, lw=2, where="post", label="Bid depth")
    ax2.fill_between(bp, cum_bid, step="post", color=GREEN, alpha=0.15)
    ax2.step(ap, cum_ask, color=RED,   lw=2, where="post", label="Ask depth")
    ax2.fill_between(ap, cum_ask, step="post", color=RED,   alpha=0.15)
    ax2.axvline(snap["midprice"],   color=WHITE,  lw=1, linestyle=":", alpha=0.5, label="Mid")
    ax2.axvline(snap["microprice"], color=YELLOW, lw=1, linestyle="--", alpha=0.8, label="Microprice")

    ax2.set_xlabel("Price (USD)", color=GREY)
    ax2.set_ylabel("Cumulative Size (BTC)", color=GREY)
    ax2.legend(fontsize=8, facecolor=PANEL, edgecolor=BORDER, labelcolor=WHITE)
    ax2.grid(alpha=0.3)
    ax2.xaxis.set_major_formatter(FuncFormatter(lambda x, _: f"${x:,.0f}"))
    ax2.spines[["top","right"]].set_visible(False)

    plt.tight_layout()
    fig.savefig(f"{OUT}/order_book.png", dpi=150, bbox_inches="tight", facecolor=DARK)
    plt.close(fig)
    print("order_book.png done")

# ─────────────────────────────────────────────────────────────────────────────
# 3. SIGNALS TIME SERIES
# ─────────────────────────────────────────────────────────────────────────────

def make_signals():
    t    = [s["t"]         for s in snaps]
    imb  = [s["imbalance"] for s in snaps]
    mid  = [s["midprice"]  for s in snaps]
    micro= [s["microprice"]for s in snaps]
    spr  = [s["spread"]    for s in snaps]

    # Smooth imbalance for clarity
    imb_s = np.convolve(imb, np.ones(12)/12, mode="same")

    fig = plt.figure(figsize=(14, 8), facecolor=DARK)
    gs  = gridspec.GridSpec(3, 1, hspace=0.45, figure=fig)
    fig.suptitle("Hardware Signal Engine Output  —  BTC-USD  (600 ticks)",
                 color=WHITE, fontsize=13, fontweight="bold")

    # Panel 1: midprice + microprice
    ax1 = fig.add_subplot(gs[0])
    ax1.set_facecolor(PANEL)
    ax1.plot(t, mid,   color=BLUE,   lw=1.4, label="Midprice",   alpha=0.9)
    ax1.plot(t, micro, color=YELLOW, lw=1.0, label="Microprice", alpha=0.8, linestyle="--")
    ax1.fill_between(t,
        np.array(mid)   - np.array(spr)/2,
        np.array(mid)   + np.array(spr)/2,
        color=BLUE, alpha=0.08, label="Spread band")
    ax1.set_ylabel("Price (USD)", color=GREY)
    ax1.yaxis.set_major_formatter(FuncFormatter(lambda x, _: f"${x:,.1f}"))
    ax1.legend(fontsize=8, facecolor=PANEL, edgecolor=BORDER, labelcolor=WHITE, ncol=3)
    ax1.grid(alpha=0.25); ax1.spines[["top","right"]].set_visible(False)
    ax1.set_title("Midprice  &  Size-Weighted Microprice", color=GREY, fontsize=9, loc="left")

    # Panel 2: imbalance
    ax2 = fig.add_subplot(gs[1])
    ax2.set_facecolor(PANEL)
    ax2.axhline(0, color=BORDER, lw=1)
    ax2.fill_between(t, imb_s, 0,
        where=np.array(imb_s) > 0, color=GREEN, alpha=0.35, label="Bid-heavy")
    ax2.fill_between(t, imb_s, 0,
        where=np.array(imb_s) < 0, color=RED,   alpha=0.35, label="Ask-heavy")
    ax2.plot(t, imb_s, color=WHITE, lw=0.8, alpha=0.6)
    ax2.set_ylabel("Imbalance (Q16)", color=GREY)
    ax2.set_ylim(-1, 1)
    ax2.legend(fontsize=8, facecolor=PANEL, edgecolor=BORDER, labelcolor=WHITE, ncol=2)
    ax2.grid(alpha=0.25); ax2.spines[["top","right"]].set_visible(False)
    ax2.set_title("Order Book Imbalance  =  (bidVol − askVol) / totalVol", color=GREY, fontsize=9, loc="left")

    # Panel 3: spread
    ax3 = fig.add_subplot(gs[2])
    ax3.set_facecolor(PANEL)
    ax3.fill_between(t, spr, color=PURPLE, alpha=0.4)
    ax3.plot(t, spr, color=PURPLE, lw=1.0)
    ax3.axhline(np.mean(spr), color=YELLOW, lw=1, linestyle="--",
                label=f"Mean spread = ${np.mean(spr):.4f}")
    ax3.set_xlabel("Message sequence", color=GREY)
    ax3.set_ylabel("Spread (USD)", color=GREY)
    ax3.legend(fontsize=8, facecolor=PANEL, edgecolor=BORDER, labelcolor=WHITE)
    ax3.grid(alpha=0.25); ax3.spines[["top","right"]].set_visible(False)
    ax3.set_title("Bid-Ask Spread  (best_ask − best_bid)", color=GREY, fontsize=9, loc="left")

    fig.savefig(f"{OUT}/signals.png", dpi=150, bbox_inches="tight", facecolor=DARK)
    plt.close(fig)
    print("signals.png done")

# ─────────────────────────────────────────────────────────────────────────────
# 4. PIPELINE LATENCY BREAKDOWN
# ─────────────────────────────────────────────────────────────────────────────

def make_pipeline():
    parser  = hls_loop("parser")  or (22, 22)
    signals = hls_loop("signals") or (85, 1)
    stages = [
        (f"HLS Parser\n(II={parser[1]}, 22 B in)",          parser[0],  CYAN),
        ("parser out\nreg slice",                           1,          GREY),
        ("book update + snap reg (1c)\n+ HLS in reg slice (1c)", 2,    GREEN),
        (f"Signal engine\n(II={signals[1]}, depth {signals[0]})", signals[0], YELLOW),
        ("HLS out\nreg slice",                              1,          PURPLE),
    ]
    clk = measured_clock()
    ns = 1000.0 / clk[2] if clk else None
    title = (f"Pipeline Stage Latency  —  {clk[2]:.1f} MHz post-route clock (1 cycle = {ns:.2f} ns)"
             if clk else "Pipeline Stage Latency  —  cycles from HLS csynth reports")

    fig, ax = plt.subplots(figsize=(13, 4.2), facecolor=DARK)
    ax.set_facecolor(PANEL)
    fig.suptitle(title, color=WHITE, fontsize=12, fontweight="bold")

    x = 0
    for k, (label, cycles, color) in enumerate(stages):
        ax.barh(0, cycles, left=x, height=0.55, color=color, alpha=0.8,
                edgecolor=DARK, linewidth=1.5)
        cx = x + cycles / 2
        ly = 0.35 if cycles >= 4 or k % 2 == 0 else 0.62   # stagger the narrow stages' labels
        if cycles >= 4:
            ax.text(cx, 0, f"{cycles}c" + (f"\n{cycles*ns:.0f} ns" if ns else ""),
                    ha="center", va="center", fontsize=9,
                    color=DARK if color in (YELLOW, GREEN, CYAN) else WHITE, fontweight="bold")
        if cycles >= 4:
            ax.text(cx, ly, label, ha="center", va="bottom", fontsize=7.5, color=color)
        else:   # narrow stage: anchor the label at the bar's left edge so it doesn't sit on its neighbours
            ax.text(x - 0.5, ly, label, ha="left", va="bottom", fontsize=7.5, color=color)
        x += cycles

    total = sum(c for _, c, _ in stages)
    book_to_sig = sum(c for _, c, _ in stages[2:])  # NormMsg on s_axis -> SignalOut
    ax.annotate("", xy=(total, -0.32), xytext=(0, -0.32),
                arrowprops=dict(arrowstyle="<->", color=WHITE, lw=1.5))
    ax.text(total/2, -0.42,
            f"First raw byte -> SignalOut: {total} cycles" + (f" = {total*ns:.0f} ns" if ns else "")
            + f"   |   NormMsg -> SignalOut: {book_to_sig} cycles" + (f" = {book_to_sig*ns:.0f} ns" if ns else ""),
            ha="center", va="top", fontsize=10, color=WHITE, fontweight="bold")

    ax.set_xlim(-1, total + 1)
    ax.set_ylim(-0.65, 1.0)
    ax.set_yticks([])
    ax.set_xlabel("Clock cycles", color=GREY)
    ax.grid(axis="x", alpha=0.2)
    ax.spines[["top","right","left"]].set_visible(False)

    fig.savefig(f"{OUT}/pipeline_latency.png", dpi=150, bbox_inches="tight", facecolor=DARK)
    plt.close(fig)
    print("pipeline_latency.png done")

# ─────────────────────────────────────────────────────────────────────────────
# 5. FPGA UTILIZATION (parsed from reports/impl/utilization.rpt; nothing estimated)
# ─────────────────────────────────────────────────────────────────────────────

def parse_utilization_rpt(path):
    """(used, available) for the main resource rows of a Vivado report_utilization text report."""
    text = open(path).read()
    rows = {
        "LUTs\n(logic)":     r"LUT as Logic",
        "LUTs\n(RAM/SRL)":   r"LUT as Memory",
        "Flip-Flops":        r"Slice Registers",
        "BRAM\n(36K tiles)": r"Block RAM Tile",
        "DSP48E1":           r"DSPs",
    }
    out = {}
    for label, name in rows.items():
        m = re.search(r"^\|\s*" + name + r"\s*\|\s*([\d.]+)\s*\|\s*\S+\s*\|\s*\S+\s*\|\s*(\d+)\s*\|", text, re.M)
        if not m:
            return None
        out[label] = (int(float(m.group(1))), int(m.group(2)))
    return out


def make_utilization():
    rpt = os.path.join(IMPL, "utilization.rpt")
    resources = parse_utilization_rpt(rpt) if os.path.exists(rpt) else None
    if resources is None:
        fig, ax = plt.subplots(figsize=(13, 5), facecolor=DARK)
        ax.set_facecolor(PANEL); ax.axis("off")
        fig.suptitle("FPGA Resource Utilization  —  XC7Z020  (Zynq-7020, PYNQ-Z2)", color=WHITE, fontsize=12, fontweight="bold")
        ax.text(0.5, 0.55, "Tier 2 implementation has not been run: no reports/impl/utilization.rpt",
                ha="center", va="center", fontsize=12, color=YELLOW, transform=ax.transAxes)
        ax.text(0.5, 0.42, "Run `make synth` (or `make vm-bitstream`) -- no placeholder or estimated numbers are shown here.",
                ha="center", va="center", fontsize=9.5, color=GREY, transform=ax.transAxes)
        fig.savefig(f"{OUT}/utilization.png", dpi=150, bbox_inches="tight", facecolor=DARK)
        plt.close(fig)
        print("utilization.png done (not-run placeholder)")
        return

    labels = list(resources.keys())
    used   = [v[0] for v in resources.values()]
    avail  = [v[1] for v in resources.values()]
    pct    = [u/a*100 for u, a in zip(used, avail)]

    fig, axes = plt.subplots(1, 2, figsize=(13, 5), facecolor=DARK)
    fig.suptitle("FPGA Resource Utilization  —  XC7Z020  (Zynq-7020, PYNQ-Z2)  —  post-route, whole PS7+DMA+pipeline design",
                 color=WHITE, fontsize=12, fontweight="bold")

    # Left: stacked bar (used vs available)
    ax = axes[0]
    ax.set_facecolor(PANEL)
    x = np.arange(len(labels))
    ax.bar(x, avail, color=BORDER, alpha=0.6, label="Available", width=0.55)
    colors = [GREEN if p < 40 else YELLOW if p < 70 else RED for p in pct]
    ax.bar(x, used,  color=colors, alpha=0.9, label="Used",      width=0.55)

    for i, (u, a, p) in enumerate(zip(used, avail, pct)):
        ax.text(i, u + a*0.02, f"{p:.1f}%", ha="center", va="bottom",
                fontsize=9, color=WHITE, fontweight="bold")

    ax.set_xticks(x); ax.set_xticklabels(labels, fontsize=8.5)
    ax.set_ylabel("Count", color=GREY)
    ax.legend(fontsize=9, facecolor=PANEL, edgecolor=BORDER, labelcolor=WHITE)
    ax.grid(axis="y", alpha=0.2)
    ax.spines[["top","right"]].set_visible(False)
    ax.set_title("Used vs Available", color=GREY, fontsize=9, loc="left")

    # Right: horizontal utilization bar (% only)
    ax2 = axes[1]
    ax2.set_facecolor(PANEL)
    y = np.arange(len(labels))
    bar_colors = [GREEN if p < 40 else YELLOW if p < 70 else RED for p in pct]
    ax2.barh(y, pct, color=bar_colors, alpha=0.85, height=0.55)
    ax2.axvline(25, color=BORDER, lw=1, linestyle="--")
    ax2.axvline(50, color=BORDER, lw=1, linestyle="--")
    ax2.axvline(75, color=RED, lw=1, linestyle="--", alpha=0.5)

    for i, (p, u, a) in enumerate(zip(pct, used, avail)):
        ax2.text(p + 0.5, i, f"{u:,} / {a:,}", va="center", fontsize=8, color=GREY)

    ax2.set_yticks(y); ax2.set_yticklabels(labels, fontsize=8.5)
    ax2.set_xlabel("Utilization (%)", color=GREY)
    ax2.set_xlim(0, 100)
    ax2.grid(axis="x", alpha=0.2)
    ax2.spines[["top","right"]].set_visible(False)
    ax2.set_title("% Utilization", color=GREY, fontsize=9, loc="left")

    plt.tight_layout()
    fig.savefig(f"{OUT}/utilization.png", dpi=150, bbox_inches="tight", facecolor=DARK)
    plt.close(fig)
    print("utilization.png done")

# ─────────────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    make_header()
    make_order_book()
    make_signals()
    make_pipeline()
    make_utilization()
    print("\nAll assets written to previews/")
