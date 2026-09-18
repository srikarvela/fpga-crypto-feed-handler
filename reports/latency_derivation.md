# Tick-to-signal latency: cycle accounting from the committed reports

All numbers below come from the files in this directory (`hls/*_csynth.rpt`,
`hls/*_cosim.rpt`, `ooc/`, `impl/`), produced by Vitis HLS 2024.1 and Vivado
2024.1 for xc7z020clg400-1 at a 4.000 ns (250 MHz) target for the pipeline
clock. This is the second design of the pipeline; the first (commit b19b49f)
measured 88 cycles from NormMsg to SignalOut and closed at ≈116 MHz on a single
250 MHz clock, and its figures are kept in section 5 for comparison. The README's
original "< 10 cycles (~40 ns at 250 MHz)" figure predates both.

## 1. The three blocks, one at a time

| Block | Source | What the report says | File |
|---|---|---|---|
| HLS feed parser | `hls/parser/parser.cpp` | loop `VITIS_LOOP_69_1`: II = **22** achieved (target 22), iteration latency **25** cycles; the `/ TICK_SIZE` divide is a reciprocal multiply from four DSP-bound 32×32 products; HLS-estimated clock 4.520 ns; 618 LUT / 1078 FF / 16 DSP (estimate) | `hls/parser_csynth.rpt` |
| Chisel order book | `chisel/src/main/scala/orderbook/` | always-ready input queue (4 deep, drops and counts on overflow) feeding a parallel compare in three register stages (compare → decide → apply) plus the snapshot register: `snap.valid` rises **5 cycles after the accept edge** with the post-update book; the stores drain one message every 3 cycles (the parser supplies at most one per 22); post-route on its own at 4.000 ns: setup WNS +0.013 ns, 0 failing, **250.8 MHz** setup-limited, 1994 LUT / 3099 FF | `ooc/N_4.000ns/`, `OrderBookTest` |
| HLS signal engine | `hls/signals/signals.cpp` | loop `VITIS_LOOP_38_1`: II = **1** achieved (target 1), iteration latency (pipeline depth) **56** cycles; HLS-estimated clock 5.640 ns; 23999 LUT / 35422 FF / 88 DSP (estimate) | `hls/signals_csynth.rpt` |

Why the signal engine is 56 cycles deep now (85 before): the four divisions
(`imbalance`, `microprice`, `vwap_bid`, `vwap_ask`) were generic 64-by-37-bit
Vitis HLS divider cores (57–68 cycles each). They are now exact restoring dividers
sized to each quotient's real range — 17 bits for the Q16 imbalance (|Δ| ≤ total),
32 bits for the microprice (it lies between best bid and best ask), 40 bits for the
Q8 VWAPs (a price-scale average) — written as an unrolled subtract-and-select per
quotient bit, which HLS schedules as one bit per pipeline stage. The 40-bit VWAP
divider therefore sets the depth. No approximation: the C testbench checks all six
signals bit-for-bit against wide-integer reference division on a directed book, four
edge cases and 400 random books, and C/RTL co-simulation runs the same testbench
against the generated RTL.

Co-simulation (`hls/*_cosim.rpt`, xsim, Verilog): parser `Fail`-flagged
table row but `parser_tb PASSED` and `C/RTL co-simulation finished: PASS` in the log
(the `Status` column reflects the `ap_ctrl_none` + non-blocking-stream structure,
`COSIM 212-382`); signal engine likewise PASS, with measured latency
56–57 cycles and interval 1–2 over the 405
snapshots.

## 2. Cycle accounting, NormMsg in -> SignalOut out

Counting from the cycle in which a packed NormMsg is accepted on the order book's
`s_axis`:

| Step | Cycles | Source |
|---|---:|---|
| Order book: input queue, compare, decide, apply, snapshot register (`snap.valid`) | 5 | `OrderBook.UPDATE_LATENCY`, checked by `OrderBookTest` |
| HLS AXI-Stream input register slice on `in_snap` | 1 | `compute_signals.v` (`regslice_both_in_snap`) |
| Signal engine pipeline depth | 56 | `hls/signals_csynth.rpt`, iteration latency |
| HLS AXI-Stream output register slice on `out_sig` | 1 | `compute_signals.v`; 56–57 cycles in → out measured in cosim |
| **NormMsg -> SignalOut** | **63** | |
| Raw bytes -> NormMsg (parser, 22 bytes at one byte per cycle) + AXIS transfer | +26 | `hls/parser_csynth.rpt`, iteration latency |
| **First raw byte -> SignalOut** | **89** | |

At the pipeline clock the full design achieves post-route (223.8 MHz, section
4) that is **≈ 282 ns from NormMsg to signal and ≈ 398 ns from the
first raw byte**; at exactly 250 MHz it would be 252 ns / 356 ns.
The order book itself contributes 5 cycles; the 56 cycles are the
signal engine, and within it the 40-quotient-bit VWAP divider. Spread and midprice
(no division) are ready inside the engine after a few cycles but leave with the rest
of the record; there is no separate fast output. The "< 10 cycles" figure is **not
supported** by any report here.

## 3. The order book on its own, post-route (`ooc/N_4.000ns/`)

`tcl/orderbook_ooc.tcl`: `chisel/generated/OrderBook.v` (depth 10, 32-bit
price/size) synthesized out-of-context, placed and routed at a 4.000 ns clock.

| Slice LUTs | FF | WNS (ns) / failing | WHS (ns) / failing | constraints met | setup-limited Fmax |
|---:|---:|---:|---:|---|---:|
| 1994 | 3099 | +0.013 / 0 of 7893 | +0.068 / 0 | yes | **250.8 MHz** |

Worst setup path: `word_reg[3]/C` → `bidStore/insertBeforeR_5_reg/D`, 3.980 ns
(1.658 ns logic, 2.322 ns route, 6 levels: CARRY4=4 LUT2=1 LUT4=1).
The hold failures are input-port → first-register paths under the out-of-context
ideal-clock assumption (0.500 ns input delay against a clock with no buffer), the
same artifact as in the sibling repos; not claimed either way. Three earlier
versions of this block were measured on the way here: the original single-cycle
update with its combinational imbalance divider (WNS −306 ns, 3.2 MHz), the same
without the divider (−4.060 ns, 124 MHz: the insert-position decode fanned out to
647 clock enables), and a two-stage compare+decide / apply split (−2.261 ns, 160 MHz:
routing from twenty comparators into the encoders). Their reports are not committed;
the numbers are quoted from those runs.

## 4. The whole design, post-route, through `write_bitstream` (`impl/`)

`tcl/vivado_project.tcl` + `tcl/block_design.tcl`: PS7 with **two fabric clocks** —
FCLK_CLK0 at 100 MHz for the AXI DMA, AXI-Lite and interconnects, FCLK_CLK1 at
250 MHz for the pipeline (parser, book, signal engine, width converter) — joined by
two AXI4-Stream clock converters (8-bit in, 32-bit out). Neither HLS block is ever
back-pressured: the book's `s_axis_tready` is a constant 1 (its input queue absorbs
messages), and a drop-on-overflow FIFO (`rtl/axis_drop_fifo.v`, 32 records, Icarus-tested)
sits between the signal engine and the 28-byte → 32-bit width converter, so Vivado removes
both HLS blocks' stall logic — in the first two-clock build those ready → clock-enable
fan-out nets were every one of the 10 097 failing endpoints (WNS −0.909 ns). Bitstream written
(`build/feed_handler_bd_wrapper.bit`, gitignored, never loaded on a board).

| clock | domain | period (ns) | WNS (ns) / failing | WHS (ns) / failing | setup-limited Fmax |
|---|---|---:|---:|---:|---:|
| `clk_fpga_1` | parser + book + signal engine + width converter | 4.000 | -0.469 / 3611 of 70286 | +0.020 / 0 | **223.8 MHz** |
| `clk_fpga_0` | AXI DMA, AXI-Lite, interconnects, clock-converter far sides | 10.000 | +0.968 / 0 of 9955 | +0.024 / 0 | 110.7 MHz |

Whole design: 18039 Slice LUTs (16532 logic + 1507 memory) = 34 %,
33173 FFs, 5 BRAM tiles, 104 DSPs; `timing_summary.rpt` states
"Timing constraints are not met". The pipeline clock does not close: WNS -0.469 ns, 3611 of 70286 endpoints failing, setup-limited 223.8 MHz.
Worst setup path in the design: `feed_handler_bd_i/signals_0/inst/snap_asks_price_reg_9218_pp0_iter15_reg_reg[4]/C` → `feed_handler_bd_i/signals_0/inst/select_ln75_reg_10619_reg[0]/R`, 3.908 ns
(1.582 ns logic, 2.326 ns route, 6 levels: CARRY4=4 LUT3=1 LUT4=1).

What was tried against the residual paths, all inside the HLS signal engine: Vivado's
`Flow_PerfOptimized_high` + retiming and `Performance_ExplorePostRoutePhysOpt`
strategies (WNS −0.518 ns, no better than the defaults), and a Vitis HLS
free-running pipeline (`style=frp`), which HLS accepted but which doubled the depth
to 105 cycles and drove the same 1984-flip-flop input register-slice clock-enable net
from its valid-tracking register (WNS −1.455 ns). The wide AXI4-Stream input register
slice's enable fan-out is intrinsic to how Vitis HLS builds this interface; closing it
would need a narrower or split input stream, which is not done.

## 5. Summary against the earlier figures

| Figure | README as first written | First measured design (b19b49f) | This design |
|---|---|---|---|
| Parser II | 22 | 22 | **22** |
| Signal engine II / depth | 1 | 1 / 85 | **1 / 56** |
| Book update | 1 cycle, single stage | 1 register stage holding a 310 ns divide (3.2 MHz alone); valid carried the pre-update book | queue + 3-stage compare/decide/apply, **250.8 MHz alone**, valid carries the post-update book, always ready (stores drain one per 3 cycles) |
| NormMsg → SignalOut | < 10 cycles, ~40 ns | 88 cycles (~760 ns at 116 MHz) | **63 cycles** (≈ 282 ns at 223.8 MHz) |
| First raw byte → SignalOut | — | 111 cycles | **89 cycles** (≈ 398 ns) |
| Pipeline clock | 250 MHz | single 250 MHz clock, WNS −4.624 ns, ≈116 MHz | 250 MHz pipeline clock: WNS -0.469 ns, 223.8 MHz setup-limited; DMA on a separate 100 MHz clock |
| Whole design | — | 38 814 LUT (73 %), 104 DSP | 18039 LUT (34 %), 104 DSP |
| Deployed on PYNQ-Z2 | yes | not run | **not run** (no board reachable) |
