<p align="center">
  <img src="docs/previews/header.png" alt="FPGA Crypto Feed Handler" width="100%" />
</p>

# FPGA Crypto Market-Data Feed Handler + Order Book

A hardware pipeline that ingests a live crypto exchange market-data stream, parses it in silicon, maintains a top-N order book, and computes real-time trading signals — the same "feed handler + book builder" architecture used in production HFT systems.

This project combines a **Chisel-generated order book engine** with **Vitis HLS IP blocks** and a **Python golden-model verifier**, targeting the PYNQ-Z2 Zynq SoC. A bitstream has been built for it; it has **not** been run on the board (see [What IS NOT implemented](#-what-is-not-implemented)).

---

## 💡 Concept & Purpose

This pipeline is designed as a **hardware-accurate, quantifiably latency-bound** implementation of a crypto feed handler — not a software simulation or RTL toy example.

The implementation focuses on:
- Demonstrating a real HFT microarchitecture in silicon-level hardware
- Showing how parameterized RTL generators (Chisel) replace hand-written Verilog
- Checking hardware output against a software golden model on replayed market data (designed and scripted; not yet executed on hardware)
- Producing concrete numbers from the tools, not targets: NormMsg-to-signal latency in cycles, LUT/FF/DSP/BRAM utilization, post-route Fmax

The goal is a **complete, verifiable, demo-able system** — from live WebSocket data to bitstream to verified output — not just a block of RTL. As of the committed reports the chain reaches the bitstream; the board step has not been taken.

---

## 🚧 Project Status

**Current version:** `v1.0-full-stack`

✔ Chisel order book engine (parallel-compare sorted insert, depth-N parametric; always-ready input queue + three register stages) — **closes 250 MHz on its own**: post-route WNS +0.013 ns, 0 failing setup endpoints ([reports/ooc/N_4.000ns](reports/ooc/N_4.000ns))  
✔ HLS binary parser (22-byte wire format → NormMsg AXI-Stream) — Vitis HLS 2024.1 csynth: **II = 22 achieved**, iteration latency 25 ([reports/hls/parser_csynth.rpt](reports/hls/parser_csynth.rpt))  
✔ HLS signal engine (imbalance Q16, microprice, spread, VWAP Q8) — csynth: **II = 1 achieved, 56-cycle pipeline depth** (was 85: the four divisions are now exact quotient-sized restoring dividers) ([reports/hls/signals_csynth.rpt](reports/hls/signals_csynth.rpt))  
✔ ChiselTest unit suite (9 cases: bid/ask sorted insert, delete, update, snapshot timing, midprice, back-to-back queueing, overflow drop count, depth cap) — passing (sbt 1.9.9)  
✔ HLS C-sim + C/RTL co-sim: both testbenches PASS; the signal-engine testbench checks all six signals bit-for-bit against wide-integer reference division on 405 books ([reports/hls/](reports/hls))  
✔ Tcl automation: HLS → Chisel Verilog → Vivado block design → synthesis + implementation, runnable from macOS into a Parallels Windows VM  
✔ Vivado block design (PS7 + AXI DMA on a 100 MHz clock, parser + OrderBook + signals + drop FIFO on a 250 MHz clock, AXI4-Stream clock converters between), built to a bitstream — pipeline clock: WNS -0.469 ns, 3611 failing endpoints; see [Synthesis results](#-synthesis-results-post-route-timing-and-utilization)  
✔ Python golden model + pytest suite  
✔ Live Coinbase WebSocket feed adapter (binary replay capture)  
✔ PYNQ-Z2 DMA driver with hw-vs-golden diff checker — written, **not yet run on a board** (Tier 3 unverified)  

**Constraint vs. measured.** The design is constrained at 250 MHz (4.000 ns). The Vivado and Vitis HLS reports committed under [reports/](reports) show it does **not** meet that constraint: post-route setup WNS is −4.624 ns with 58 628 of 90 271 endpoints failing, a setup-limited clock of about 116 MHz (hold is met). Every performance figure in this README is taken from those reports; the numbers are in [Synthesis results](#-synthesis-results-post-route-timing-and-utilization) and the cycle accounting in [reports/latency_derivation.md](reports/latency_derivation.md).

---

## 📐 Architecture Overview

```
[Python host / Coinbase WS]
         │
         │  22-byte binary wire format (UDP or DMA)
         ▼
┌─────────────────────┐
│   HLS Feed Parser   │  Vitis HLS · II=22, depth 25 (csynth)
│  raw bytes → NormMsg│  price normalization (ticks)
└────────┬────────────┘
         │  AXI-Stream (128-bit packed NormMsg)
         ▼
┌─────────────────────────────────────────────────────┐
│            Chisel Order Book Engine                 │
│  ┌─────────────────────┐  ┌─────────────────────┐  │
│  │  PriceLevelStore    │  │  PriceLevelStore    │  │
│  │  Bids (desc sort)   │  │  Asks (asc sort)    │  │
│  │  parallel compare   │  │  parallel compare   │  │
│  │  3-stage insert/del │  │  3-stage insert/del │  │
│  └──────────┬──────────┘  └──────────┬──────────┘  │
│             └────────────┬───────────┘             │
│                          │  BookSnapshot            │
│                levels · midprice · seqNum           │
└──────────────────────────┬──────────────────────────┘
                           │  AXI-Stream snapshot
                           ▼
               ┌───────────────────────┐
               │  HLS Signal Engine    │  Vitis HLS · II=1, 56-cycle depth
               │  microprice · spread  │
               │  VWAP bid/ask (Q8)    │
               └───────────┬───────────┘
                           │  SignalOut → PS (AXI DMA)
                           ▼
               [Python PYNQ driver + golden diff]
```

The order book uses a **parallel shift-register structure**: all depth slots are compared simultaneously each cycle, producing a sorted insert, update, or delete in a single clock cycle with no multi-cycle arbitration.

<p align="center">
  <img src="docs/previews/order_book.png" alt="Order Book Depth Snapshot" width="90%" />
</p>

---

## ⚡ Why Hardware?

Software order books on CPUs run at microsecond latencies, limited by memory bandwidth, branch mispredictions, and OS scheduling jitter. An FPGA implementation achieves:

- **Deterministic update** — an always-ready input queue and three register stages (compare, decide, apply), no cache misses, no branch prediction; the book closes 250 MHz on its own
- **Pipelined throughput** — the HLS parser accepts one message per 22 clock cycles (`reports/hls/parser_csynth.rpt`: II achieved 22, target 22). No committed csynth or cosim report measures a messages-per-second rate, and the 250 MHz clock that a rate figure would need is not met post-route, so no msg/s number is quoted here.
- **Zero-copy data path** — AXI-Stream connects all blocks without software intervention
- **Fixed, known latency** — 63 cycles from a NormMsg accepted by the book to SignalOut leaving the signal engine (≈ 282 ns at the 223.8 MHz the pipeline clock achieves post-route), 89 cycles (≈ 398 ns) from the first raw byte. The book contributes 5 cycles; the 56 are the signal engine's exact dividers. Derivation in [reports/latency_derivation.md](reports/latency_derivation.md).

This mirrors the architecture used in real low-latency trading infrastructure, where the feed handler and book builder are co-located in FPGA fabric.

---

## 🚀 Performance

<p align="center">
  <img src="docs/previews/pipeline_latency.png" alt="Pipeline Latency Breakdown" width="90%" />
</p>

| Metric | Constraint / design intent | Measured (Vivado / Vitis HLS 2024.1, xc7z020clg400-1) | Evidence |
|---|---|---|---|
| Pipeline clock | 250 MHz (4.000 ns) on FCLK_CLK1 | **Constraint not met.** Setup: WNS -0.469 ns, 3611 of 70286 endpoints failing → setup-limited Fmax ≈ 223.8 MHz. Hold: WHS +0.020 ns, 0 failing | `reports/impl/timing_summary.rpt` |
| DMA / AXI-Lite clock | 100 MHz on FCLK_CLK0 | WNS +0.968 ns, 0 failing; WHS +0.024 ns | `reports/impl/timing_summary.rpt` |
| Order book alone (OOC) | 4.000 ns | setup WNS +0.013 ns, 0 failing → 250.8 MHz; hold +0.068 ns on 0 OOC input-port paths | `reports/ooc/N_4.000ns/` |
| Parser initiation interval | II = 22 | **II achieved 22, target 22** (iteration latency 25; HLS-estimated clock 4.520 ns) | `reports/hls/parser_csynth.rpt` |
| Book update | minimal | **5 cycles** accept-edge to `snap.valid` (queue 1 + message register 1 + compare/decide/apply/snapshot 3), always ready, stores drain one per 3 cycles, snapshot carries the post-update book | `OrderBook.UPDATE_LATENCY`, `OrderBookTest` |
| Signal engine II | 1 | **II achieved 1, target 1**, iteration latency **56 cycles** (HLS-estimated clock 5.640 ns); cosim 56–57 cycles | `reports/hls/signals_csynth.rpt`, `signals_cosim.rpt` |
| NormMsg → SignalOut | minimal | **63 cycles** = 5 (book) + 1 (HLS input slice) + 56 (engine) + 1 (HLS output slice) ≈ **282 ns**; **89 cycles ≈ 398 ns** from the first raw byte | `reports/latency_derivation.md` |
| Utilization (full design, post-route) | fit in XC7Z020 | **18039 Slice LUTs** (16532 logic + 1507 memory) of 53 200 = 34 %; **33173 FFs** of 106 400 = 31 %; **5 BRAM tiles**; **104 DSPs** of 220 | `reports/impl/utilization.rpt` |
| Target device | Zynq XC7Z020 (PYNQ-Z2) | same; bitstream built, not loaded |

The figure above is generated from the same reports (`docs/gen_visuals.py` reads `reports/hls/*_csynth.rpt` and `reports/impl/timing_summary.rpt`); nothing in it is typed in by hand.

---

## 📏 Synthesis results: post-route timing and utilization

Every number here is parsed from the committed reports in [reports/](reports) (`docs/gen_visuals.py` for the chart, the text from the same files). Flow: `make vm-hls` (both HLS blocks: csim → csynth → cosim → export_ip), `make vm-ooc` (OrderBook alone, out-of-context synth + P&R at 4.000 ns), `make vm-bitstream` (the full PS7 + AXI DMA + parser + OrderBook + signal-engine block design through `write_bitstream`, DMA domain on FCLK_CLK0 = 100 MHz, pipeline on FCLK_CLK1 = 250 MHz). Fmax = 1 / (period − WNS) is the setup-limited clock from post-route slack, as in the sibling cordic-engine repo.

| run | scope | Slice LUTs | FF | DSP | BRAM | clock / period (ns) | WNS (ns) / failing | WHS (ns) / failing | constraints met | Fmax (MHz) |
|---|---|---:|---:|---:|---:|---|---:|---:|---|---:|
| `ooc/N_4.000ns` | OrderBook alone, OOC | 1994 | 3099 | 0 | 0 | 4.000 | +0.013 / 0 of 7893 | +0.068 / 0 | yes | **250.8** |
| `impl/` pipeline clock | parser + book + signals + width converter | 18039 (whole design) | 33173 | 104 | 5 | clk_fpga_1 / 4.000 | -0.469 / 3611 of 70286 | +0.020 / 0 | no | **223.8** |
| `impl/` DMA clock | AXI DMA + AXI-Lite + interconnects | | | | | clk_fpga_0 / 10.000 | +0.968 / 0 of 9955 | +0.024 / 0 | yes | 110.7 |

<p align="center">
  <img src="docs/previews/utilization.png" alt="FPGA Resource Utilization (post-route)" width="90%" />
</p>

**Reading the results.**

- **The pipeline clock (250 MHz) does not close: WNS -0.469 ns, 3611 of 70286 endpoints failing.** Worst setup path in the design: `feed_handler_bd_i/signals_0/inst/snap_asks_price_reg_9218_pp0_iter15_reg_reg[4]/C` → `feed_handler_bd_i/signals_0/inst/select_ln75_reg_10619_reg[0]/R`, 3.908 ns (1.582 ns logic, 2.326 ns route, 6 levels). The DMA domain at 100 MHz: WNS +0.968 ns. Hold on both clocks: +0.020 / +0.024 ns. `report_timing_summary` states "Timing constraints are not met".
- **The order book closes 250 MHz on its own** (setup WNS +0.013 ns, 0 failing, 250.8 MHz setup-limited) now that its update is three register stages (compare → decide → apply) behind an always-ready input queue, and its imbalance divide has moved into the signal engine. The single-cycle original was 3.2 MHz alone because of that 72÷42-bit divide (310 ns, 1320 logic levels); without the divide it was 124 MHz (the insert decode fanned out to 647 clock enables); the two-stage split was 160 MHz; three stages meet the constraint. The OOC hold failures (0 endpoints, +0.068 ns) are input-port paths under ideal-clock assumptions and are not claimed either way.
- **The HLS blocks meet their II targets.** Parser II = 22 (target 22, iteration latency 25); signal engine II = 1 (target 1), pipeline depth 56 (was 85). HLS's own clock estimates are 4.520 ns and 5.640 ns (it chains the last divider step into the output write); the post-route pipeline-clock result above is what those blocks actually do in silicon. Neither block is ever back-pressured (constant-1 TREADY from the book's input queue and from `rtl/axis_drop_fifo.v`), which is what removed their ready → clock-enable fan-out nets: in the first two-clock build those were all 10 097 failing endpoints (WNS −0.909 ns).
- **Utilization (`reports/impl/utilization.rpt`).** 18039 Slice LUTs (16532 as logic, 1507 as memory) of 53 200 = 34 %; 33173 Slice Registers = 31 %; 5 Block RAM tiles; 104 DSPs. Per block (`utilization_hierarchical.rpt`, LUT / FF / DSP): signal engine 12728 / 25215 / 88, order book 1962 / 3056 / 0, parser 365 / 820 / 16, DMA 1324 / 1923 / 0. The first design was 38 814 LUTs (73 %), almost all of it the generic 64-bit dividers.
- **Tier 3 (hardware) has not been run.** No PYNQ-Z2 was reachable while these reports were generated, so nothing here is board-verified. Two integration gaps remain from the build alone: neither HLS stream carries `TLAST`, so the AXI DMA S2MM channel has nothing to terminate a transfer on, and `board/pynq/pynq_driver.py` unpacks 25-byte records while the HLS `SignalOut` record is 28 bytes (C-struct alignment), now delivered as seven 32-bit DMA beats.

---

## 🚫 What IS NOT implemented

- **Sub-10-cycle tick-to-signal.** The measured NormMsg → SignalOut latency is 63 cycles (5 in the book, 56 in the signal engine's exact dividers), 89 from the first raw byte. Getting the divided signals out in under 10 cycles would need approximate (reciprocal-multiply) division or a radix-4/8 divider; neither is built.
- **The 250 MHz pipeline constraint is not met post-route: WNS -0.469 ns, 3611 failing endpoints, setup-limited ≈ 223.8 MHz.** The whole design does not run at 250 MHz: the AXI DMA, AXI-Lite and interconnects are on a separate 100 MHz clock with AXI4-Stream clock converters at the two boundaries.
- **Never run on PYNQ-Z2 hardware.** No bitstream has been loaded onto a board, no data has been streamed over AXI DMA, and no hardware-vs-golden diff has been executed. `build/feed_handler_bd_wrapper.bit` exists only locally (gitignored) and there is no `reports/hw/`.
- **The board driver is unexercised.** `board/pynq/pynq_driver.py` has only ever run in its `pynq`-absent dry-run mode. Its 25-byte record format does not match the 28-byte HLS `SignalOut` word, and the S2MM path has no `TLAST` source, so it would need changes before a board run could complete.
- **Hold in the OOC book run is not closed** (0 input-port endpoints at +0.068 ns, the ideal-clock artifact); in the full design with the real clock network hold is +0.020 / +0.024 ns.
- **No message-rate measurement.** II = 22 is the only throughput figure any report supports; no csynth, cosim or implementation report measures messages per second.
- **Back-pressure is replaced by bounded-loss queues.** The book's input queue (4 messages) and the output FIFO (32 records) never stall the HLS blocks; they drop and count instead. At the specified rates (one message per 22 cycles in, one 32-bit beat per cycle out) neither fills, but a DMA stall longer than 32 records' worth of arrivals loses records. No DMA-stall test has been run.
- **No power numbers.** Timing and area are measured; power is not reported.
- **Single instrument, fixed depth 10, compile-time tick size.** The runtime-configurable variants in the roadmap are not built.

---

## 🔢 Signals Computed

<p align="center">
  <img src="docs/previews/signals.png" alt="Hardware Signal Engine Output" width="90%" />
</p>

| Signal | Formula | Format |
|---|---|---|
| **Imbalance** | (bidVol − askVol) / (bidVol + askVol) | Q16 signed |
| **Midprice** | (best\_bid + best\_ask) / 2 | ticks |
| **Microprice** | (bestBid·askVol + bestAsk·bidVol) / totalVol | ticks |
| **Spread** | best\_ask − best\_bid | ticks |
| **VWAP bid** | Σ(price·size) / Σ(size) over top-N bid levels | Q8 |
| **VWAP ask** | Σ(price·size) / Σ(size) over top-N ask levels | Q8 |

---

## 🧪 Verification Strategy

Hardware correctness is verified at three levels:

**Level 1 — Unit (ChiselTest)**  
Nine test cases exercise the Chisel order book directly: sorted bid insert, sorted ask insert, level deletion, in-place size update, snapshot timing against `UPDATE_LATENCY` with the post-update book, midprice arithmetic, back-to-back messages absorbed by the input queue, the overflow drop counter, and depth-cap enforcement. `tb/tb_axis_drop_fifo.v` (Icarus) checks the output FIFO's in-order delivery and drop counting under downstream stalls.

**Level 2 — HLS C-sim + Co-sim**  
Each HLS block has a standalone C++ testbench. Co-simulation re-runs the same testbench against Verilog-level RTL after synthesis to confirm functional equivalence. Both pass (`parser_tb PASSED`, `signals_tb PASSED`, `C/RTL co-simulation finished: PASS`); the signal-engine testbench compares all six signals bit-for-bit with wide-integer reference division on a directed book, four edge cases and 400 random books, and the parser testbench checks the reciprocal-multiply divide against `/` on 200 000 inputs. The `*_cosim.rpt` tables show `Status Fail` alongside, which the HLS log attributes to the `ap_ctrl_none` + non-blocking `while (!stream.empty())` structure (`COSIM 212-382`) — see [reports/latency_derivation.md](reports/latency_derivation.md).

**Level 3 — Golden model diff (Python)**  
A NumPy reference order book processes the same binary replay file the hardware would. The PYNQ driver is written to collect hardware signal outputs via DMA and call `diff_hw_vs_ref()`, flagging any integer difference beyond a configurable tolerance (default: 1 LSB). **This level has not been executed:** no hardware output exists yet.

```
live Coinbase WS
       │
       ├──► binary replay file (.bin)
       │           │
       │    ┌──────┴──────┐
       │    │             │
       │  Python        FPGA (DMA)
       │  golden        hw output
       │    │             │
       │    └──────┬──────┘
       │         diff
       │     PASS / FAIL
```

---

## ⚙️ Core Components

### Chisel Order Book (`chisel/`)
- `Types.scala` — `MarketMsg`, `Level`, `BookSnapshot` bundle definitions
- `PriceLevelStore.scala` — single-sided parallel-compare sorted store in three register stages (compare → decide → apply); O(1) insert/update/delete in the number of levels; parametric depth, price bits, size bits; isBid flag controls sort direction
- `OrderBook.scala` — top-level module; always-ready AXI-Stream slave input with a 4-deep queue and drop counter; routes to bid/ask stores; midprice; snapshot registered from the post-update stores (`UPDATE_LATENCY` = 5); emits Verilog via `OrderBookVerilog` app object

### HLS Parser (`hls/parser/`)
- 22-byte little-endian wire format: `{msg_type, side, seq_num, price_raw, size_raw}`
- Price normalized to ticks via compile-time `TICK_SIZE` constant (for the default 100 it is an exact reciprocal multiply on four DSP-bound 32×32 products, checked against `/` in the testbench)
- Delete messages (`'D'`) emit `size=0` to signal level removal to the book
- Unknown message types dropped silently

### HLS Signal Engine (`hls/signals/`)
- Receives `BookSnapshot` structs from the order book
- Computes all six signals in a single II=1 pipelined loop with `#pragma HLS UNROLL` across depth slots; the four divisions are exact restoring dividers sized to each quotient (17 / 32 / 40 bits), which set the 56-cycle depth
- VWAP uses Q8 fixed-point to avoid floating-point in the fabric

### Tcl Automation (`tcl/`)
- `run_hls_parser.tcl` / `run_hls_signals.tcl` — full HLS flow: csim → csynth → cosim → IP export
- `vivado_project.tcl` — creates the Vivado project, adds the HLS IPs and `OrderBook.v`, builds the block design, runs synthesis + implementation to a bitstream, writes `reports/impl/*.rpt`
- `block_design.tcl` — PS7 with FCLK_CLK0 = 100 MHz (AXI DMA: 8-bit MM2S, 32-bit S2MM; AXI-Lite; interconnects) and FCLK_CLK1 = 250 MHz (parser → OrderBook via `rtl/orderbook_axis_wrap.v` → signals → `rtl/axis_drop_fifo.v` → 28 B-to-4 B width converter), AXI4-Stream clock converters between the domains
- `orderbook_ooc.tcl` — the OrderBook alone, out-of-context synth + P&R, `reports/ooc/`
- `run_all.tcl` — master orchestrator: HLS → Chisel Verilog → Vivado, callable as a single command
- `scripts/vivado_in_parallels.sh hls|ooc|bitstream` — runs any of the above inside a Parallels Windows VM from macOS and copies `reports/` back

### Python Feed & Verification (`python/`)
- `coinbase_feed.py` — subscribes to Coinbase Advanced Trade WebSocket L2 channel, packs messages into the 22-byte wire format, writes binary replay files
- `order_book_ref.py` — pure-Python reference book; processes replay files; computes all six signals; `diff_hw_vs_ref()` checks hw JSON against reference JSON
- `test_golden.py` — pytest suite validating the reference model itself before trusting it as a checker

### PYNQ Board Driver (`board/pynq/`)
- Loads bitstream via `pynq.Overlay`
- Allocates contiguous DMA buffers, streams replay data to fabric, collects signal output
- Calls the Python golden diff automatically; runs in dry-run mode when `pynq` package is absent

---

## 🌐 Build Tiers

This project is structured in three tiers so it can be developed and demonstrated without a board.

**Tier 1 — Simulation only** (no Vivado license or board required)

Chisel RTL simulation with ChiselTest, HLS C-simulation, and Python pytest — all runnable on any machine with SBT, Vitis HLS, and Python.

**Tier 2 — Synthesis**

Pushes the full design through Vivado synthesis and implementation. Produces timing closure reports and resource utilization numbers. Requires Vivado + Vitis HLS.

**Tier 3 — On hardware** (not yet run)

Deploys the bitstream to a PYNQ-Z2, streams live Coinbase data via DMA, and verifies hardware output against the Python golden model in real time. The driver exists; no board run has been performed, so there is no `reports/hw/` yet.

---

## 🛠️ Getting Started

**Prerequisites**

- SBT ≥ 1.9 + Java 11+ (for Chisel)
- Vitis HLS 2024.1 (for HLS C-sim / cosim)
- Vivado 2024.1 (for synthesis, Tier 2+) — natively, or inside a Parallels Windows VM via `scripts/vivado_in_parallels.sh`
- Python ≥ 3.11 + dependencies below (for golden model and feed)
- PYNQ-Z2 board + `pynq` Python package (Tier 3 only)

```bash
pip install -r python/requirements.txt
```

**Tier 1 — Run all simulations**

```bash
make sim
```

This runs:
1. `sbt test` — all six ChiselTest cases
2. `vitis_hls -f tcl/run_hls_parser.tcl` — parser csim + cosim
3. `vitis_hls -f tcl/run_hls_signals.tcl` — signal engine csim + cosim
4. `pytest python/golden/test_golden.py` — golden model unit tests

**Tier 2 — Synthesize and get timing/resource numbers**

```bash
make hls-parser hls-signals   # -> reports/hls/*_csynth.rpt, *_cosim.rpt
make synth-ooc                # OrderBook alone            -> reports/ooc/N_4.000ns/
make synth                    # full block design + bitstream -> reports/impl/, build/*.bit
# or, from macOS with Vivado in a Parallels Windows VM:
make vm-hls && make vm-ooc && make vm-bitstream
```

**Tier 3 — Capture live data and run on board**

```bash
# 1. Capture 5000 live Coinbase messages
make capture

# 2. Generate Python golden snapshots
make golden

# 3. Deploy bitstream to PYNQ and verify hardware output
make board-run
```

**Run a single step**

```bash
make chisel-test      # Chisel unit tests only
make hls-parser       # HLS parser flow only
make hls-signals      # HLS signals flow only
make chisel-verilog   # Emit OrderBook.v to chisel/generated/
make golden-test      # Python pytest only
```

---

## 🔮 Roadmap

The current implementation targets a single instrument at fixed depth-10.

Planned extensions:

- Multi-instrument fan-out (one parser → N order books in parallel)
- Configurable tick size and depth via AXI-Lite register map (no re-synthesis)
- ILA / ChipScope integration on PMOD header for live debug
- Order book imbalance → simple threshold signal generator (basic alpha logic)
- Binance feed adapter alongside Coinbase
- Exportable signal logs (CSV) from PYNQ driver

---

## 🎯 Motivation

This project demonstrates:
- Modern HDL fluency with Chisel generators instead of hand-written Verilog
- HLS as a productive path for arithmetic-heavy blocks (signals, parsing)
- Tcl as the real automation language of the Xilinx/AMD toolchain
- End-to-end hardware verification against a software reference model
- A crypto-quant relevant system with quantifiable performance metrics

It is designed to be architecturally honest — every block has a testbench, every number comes from actual simulation or synthesis, and the golden model diff provides ground truth for hardware correctness.

---

## 📁 Repository Structure

```
fpga-crypto-feed-handler/
├── Makefile                          ← make sim / synth / capture / board-run
│
├── chisel/                           ── TIER 1 core ──
│   ├── build.sbt
│   └── src/
│       ├── main/scala/orderbook/
│       │   ├── Types.scala           MarketMsg, Level, BookSnapshot bundles
│       │   ├── PriceLevelStore.scala Single-sided sorted store (parallel compare)
│       │   └── OrderBook.scala       Top-level: bid+ask stores, imbalance, midprice
│       └── test/scala/orderbook/
│           └── OrderBookTest.scala   6 ChiselTest cases
│
├── hls/
│   ├── parser/                       ── TIER 1 ──
│   │   ├── msg_types.h               Wire format + AxisWord packing
│   │   ├── parser.h / parser.cpp     22-byte raw → NormMsg AXI-Stream
│   │   └── parser_tb.cpp             C-sim testbench
│   └── signals/                      ── TIER 1 ──
│       ├── signals.h / signals.cpp   Imbalance, microprice, spread, VWAP (Q16/Q8)
│       └── signals_tb.cpp
│
├── tcl/
│   ├── run_hls_parser.tcl            csim → csynth → cosim → IP export
│   ├── run_hls_signals.tcl
│   ├── vivado_project.tcl            ── TIER 2 ── create project + impl + reports
│   ├── block_design.tcl              PS7 + DMA + parser + OrderBook + signals wired
│   └── run_all.tcl                   Master: HLS → Chisel Verilog → Vivado
│
├── python/
│   ├── feed/coinbase_feed.py         ── TIER 3 ── live WS → binary replay file
│   ├── golden/order_book_ref.py      Reference model + hw vs ref diff checker
│   ├── golden/test_golden.py         pytest: sorted insert, delete, arithmetic
│   └── requirements.txt
│
├── board/pynq/pynq_driver.py         ── TIER 3 ── load bitstream, DMA, verify (not yet run)
├── rtl/orderbook_axis_wrap.v         AXI4-Stream shell around OrderBook.v for IP Integrator
├── scripts/vivado_in_parallels.sh    macOS -> Parallels Windows VM runner (hls | ooc | bitstream)
├── reports/                          committed tool output
│   ├── hls/                          parser_/signals_ csynth.rpt + cosim.rpt
│   ├── ooc/N_4.000ns/                OrderBook OOC post-route timing + utilization
│   ├── impl/                         full-design post-route timing + utilization
│   └── latency_derivation.md         NormMsg -> SignalOut cycle accounting (63 / 89 cycles)
└── constraints/pynq_z2.xdc
```

---

## 📜 License

MIT License — see [LICENSE](LICENSE) for details.
