# Tick-to-signal latency: cycle accounting from the committed reports

All numbers below come from the files in this directory (`hls/*_csynth.rpt`,
`hls/*_cosim.rpt`, `ooc/`, `impl/`), produced by Vitis HLS 2024.1 and Vivado
2024.1 for xc7z020clg400-1 at a 4.000 ns (250 MHz) target. The README's
"< 10 cycles (~40 ns at 250 MHz)" figure was written before any of these tools
had been run; this note replaces it with what the tools actually report.

## 1. The three blocks, one at a time

| Block | Source | What the report says | File |
|---|---|---|---|
| HLS feed parser | `hls/parser/parser.cpp` | loop `VITIS_LOOP_43_1`: II = **22** achieved (target 22), iteration latency **22** cycles; HLS estimated clock 6.978 ns (a 103-bit constant multiply for `price_raw / TICK_SIZE`), estimated Fmax 143 MHz; 476 LUT / 617 FF / 16 DSP | `hls/parser_csynth.rpt` |
| Chisel order book | `chisel/src/main/scala/orderbook/` | insert / update / delete is a single-cycle parallel compare; the snapshot is a `RegNext`, so `snap.valid` rises **1 cycle** after `s_axis_tvalid`. Post-route numbers for the block on its own are in section 3. | `ooc/N_4.000ns/` |
| HLS signal engine | `hls/signals/signals.cpp` | loop `VITIS_LOOP_11_1`: II = **1** achieved (target 1), but iteration latency (pipeline depth) **85** cycles; HLS estimated clock 7.054 ns, estimated Fmax 142 MHz; 30 864 LUT (58 %) / 61 241 FF (57 %) / 88 DSP (40 %) | `hls/signals_csynth.rpt` |

Why the signal engine is 85 cycles deep: the `imbalance`, `microprice`, `vwap_bid`
and `vwap_ask` expressions are 64-bit-by-37-bit divisions. Vitis HLS implements
them as fully pipelined multi-cycle dividers (`sdiv_64ns_37ns_32_68_1` x2,
`udiv_64ns_37ns_32_68_1`, `sdiv_53ns_38ns_32_57_1`: 68- and 57-cycle cores),
which is also where most of the 30 k LUTs and 61 k flip-flops go. II = 1 is
genuine: a new snapshot can enter every cycle, but each one takes 85 cycles to
come out.

Co-simulation (`hls/*_cosim.rpt`, xsim, Verilog): both testbenches print
`PASSED` against the RTL and the HLS log ends with
`*** C/RTL co-simulation finished: PASS ***`. The report tables nevertheless show
`Status = Fail` with a measured latency of 67 cycles (parser, 4 input messages)
and 86 cycles (signal engine, 1 snapshot); the HLS log attributes this to the
`ap_ctrl_none` + non-blocking `while (!stream.empty())` structure
(`WARNING: [COSIM 212-382] ... may result in mismatches or simulation hanging`).
So co-simulation confirms functional equivalence and the 85/86-cycle signal
latency; it does not confirm any sub-10-cycle figure.

## 2. Cycle accounting, NormMsg in -> SignalOut out

Counting from the cycle in which a packed NormMsg is presented on the order
book's `s_axis` (the README's own definition of tick-to-signal):

| Step | Cycles | Source |
|---|---:|---|
| NormMsg on `s_axis` -> book updated, snapshot registered (`snap.valid`) | 1 | `OrderBook.scala` (`RegNext`) |
| HLS AXI-Stream input register slice on `in_snap` | 1 | `compute_signals.v` (`regslice_both_in_snap`) |
| Signal engine pipeline depth | 85 | `hls/signals_csynth.rpt`, iteration latency |
| HLS AXI-Stream output register slice on `out_sig` | 1 | `compute_signals.v` (`regslice_both_out_sig`); 86 cycles in -> out measured in cosim |
| **NormMsg -> SignalOut** | **88** | |
| Raw bytes -> NormMsg (parser, 22 bytes at one byte per cycle) + AXIS transfer | +23 | `hls/parser_csynth.rpt`, iteration latency |
| **First raw byte -> SignalOut** | **111** | |

At the 4.000 ns target that is ~352 ns from NormMsg to signal (~444 ns from the
first raw byte), not ~40 ns. At the clock the design actually closes at (section
3) it is proportionally longer. The "< 10 cycles" figure is **not supported** by
any report here; the sub-10-cycle part of the path is the order book alone
(1 cycle), and the signal engine that follows it is ~85 cycles.

A correctness note that also affects the accounting: `OrderBook.scala` registers
`snap.bids/asks := store` and `snap.valid := doUpdate` on the same clock edge
that applies the update, so the cycle in which `snap.valid` is high carries the
*pre-update* book with the new message's `seqNum`. The ChiselTest cases pass
because they sample the snapshot two cycles after the message, when the levels
have caught up but `valid` is already low. Aligning `valid` with the post-update
levels costs one more cycle (register `doUpdate` once more and sample `store`
then). The RTL was left as-is for these runs; the numbers above are for the
design as committed.

## 3. The order book on its own, post-route (`ooc/N_4.000ns/`)

`tcl/orderbook_ooc.tcl`: `chisel/generated/OrderBook.v` (depth 10, 32-bit
price/size) synthesized out-of-context, placed and routed at a 4.000 ns clock,
Vivado 2024.1, xc7z020clg400-1.

| Slice LUTs | FF | CARRY4 | DSP | BRAM | WNS (ns) / failing | WHS (ns) / failing | constraints met | setup-limited Fmax |
|---:|---:|---:|---:|---:|---:|---:|---|---:|
| 7641 | 2704 | 1477 | 0 | 0 | −306.218 / 2683 of 6750 | −0.002 / 1 | no | **3.2 MHz** |

The worst setup path (`ooc/N_4.000ns/setup_paths.rpt`) is
`askStore/store_5_valid_reg` → `snap_imbalance_reg[29]`: 310 ns of data-path
delay through **1320 logic levels (1242 CARRY4)**. That is the imbalance
expression in `OrderBook.scala`,
`((bidVol − askVol) << 16) / totalVol`, which Chisel emits as a single
combinational 72-bit ÷ 42-bit signed divide (`OrderBook.v`,
`_imbalance_T_8 = $signed(_imbalance_T_6) / $signed(_imbalance_T_7)`) sitting
between the level registers and the snapshot register. Vivado builds it as a
restoring-division array of ~1200 carry chains in one clock cycle. The
"single-cycle update" is therefore real only in the sense that the RTL has one
register stage; that stage cannot run anywhere near 250 MHz. The one hold
violation is an input-port path (`io_s_axis_tdata[80]` → `snap_seqNum_reg[15]`),
the usual OOC ideal-clock artifact.

Without the divider the book would be a parallel-compare shift structure (the
`PriceLevelStore` insert/delete logic plus the 10-way volume adders), which is
what the README's "O(1) single-cycle" description is really about. Moving the
imbalance divide into the HLS signal engine (which already recomputes it, 64-bit,
pipelined) and dropping it from the Chisel snapshot is the obvious fix; it has
**not** been done for these runs.

## 4. The whole design, post-route, through `write_bitstream` (`impl/`)

`tcl/vivado_project.tcl` + `tcl/block_design.tcl`: PS7 (FCLK_CLK0 = 250 MHz) +
AXI DMA (8-bit MM2S/S2MM) + `feed_parser` + `orderbook_axis_wrap` + `compute_signals`
+ AXIS width converter, xc7z020clg400-1, Vivado 2024.1, bitstream written
(`build/feed_handler_bd_wrapper.bit`, gitignored).

| Slice LUTs (logic + mem) | FF | DSP | BRAM | period (ns) | WNS (ns) / failing | WHS (ns) / failing | constraints met | setup-limited Fmax |
|---:|---:|---:|---:|---:|---:|---:|---|---:|
| 38 814 (37 129 + 1 685), 73 % | 38 646 | 104 | 2 | 4.000 | −4.624 / 58 628 of 90 271 | +0.020 / 0 | no | **116 MHz** |

Per block (`impl/utilization_hierarchical.rpt`): signal engine 33 490 LUT / 32 001 FF
/ 88 DSP; order book 2 015 LUT / 2 642 FF; parser 253 LUT / 16 DSP; DMA +
interconnect ≈ 2 600 LUT.

Two things to read carefully:

- **The order book's divider is gone here, and that is why the full design looks
  faster than the OOC run (116 MHz vs 3.2 MHz).** In the block design the book's
  `imbalance` output feeds `in_snap[1951:1920]`, which `compute_signals` never
  reads (it recomputes imbalance from the levels), so Vivado removed the 72÷42-bit
  divider as dead logic: the book shrinks from 7 641 to 2 015 LUTs. The 3.2 MHz
  OOC figure is what the book costs if anything downstream consumes
  `snap.imbalance`; the 116 MHz figure is the integrated system where nothing does.
- **Setup is still not met at 250 MHz.** WNS −4.624 ns with 58 628 of 90 271
  endpoints failing (TNS −112 µs). The ten worst paths in `impl/setup_paths.rpt`
  are all parser → order-book register-enable paths (`feed_parser_0/.../data_p1_reg`
  → `orderbook_0/.../store_*_size_reg/CE`, 8.16 ns over 10 logic levels, 75 % of
  it routing): the parallel-compare insert logic fanning a 128-bit message into
  every level's clock-enable, placed in a 73 %-full device. Hold is met (WHS
  +0.020 ns, 0 failing) now that there is a real clock network, so the OOC hold
  failures were the ideal-clock artifact they looked like.

So, for the clock claim: the fabric runs at 250 MHz only in the sense that the PS7
was configured to drive FCLK_CLK0 at 250 MHz; post-route the design would need a
period of ≈ 8.6 ns (≈ 116 MHz) to close setup, and about 140 MHz is the ceiling
Vitis HLS itself estimates for the two HLS blocks. Nothing here has been loaded
onto a board.

## 5. Summary against the README's original figures

| Figure | Original write-up | From the committed reports |
|---|---|---|
| Parser II | 22 | **22** (achieved) |
| Signal engine II | 1 | **1** (achieved), 85-cycle depth |
| Book update | 1 cycle | 1 register stage; alone it is a 310 ns combinational divide (3.2 MHz), removed as dead logic in the integrated design |
| Tick-to-signal | < 10 cycles, ~40 ns | **88 cycles** NormMsg → SignalOut, 111 from the first raw byte (≈ 760 ns / 960 ns at the 116 MHz the full design closes at; ≈ 350 / 440 ns if 250 MHz were met) |
| Clock | 250 MHz | constraint set to 250 MHz, **not met**: WNS −4.624 ns, Fmax ≈ 116 MHz post-route |
| Deployed on PYNQ-Z2 | yes | **not run** (no board reachable); bitstream exists locally, driver untested |
