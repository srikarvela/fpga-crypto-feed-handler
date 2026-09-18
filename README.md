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

✔ Chisel order book engine (parallel-compare sorted insert, depth-N parametric)  
✔ HLS binary parser (22-byte wire format → NormMsg AXI-Stream) — Vitis HLS 2024.1 csynth: **II = 22 achieved** ([reports/hls/parser_csynth.rpt](reports/hls/parser_csynth.rpt))  
✔ HLS signal engine (imbalance Q16, microprice, spread, VWAP Q8) — csynth: **II = 1 achieved, 85-cycle pipeline depth** ([reports/hls/signals_csynth.rpt](reports/hls/signals_csynth.rpt))  
✔ ChiselTest unit suite (7 cases: bid/ask sorted insert, delete, update, imbalance, midprice, depth cap) — passing (sbt 1.9.9)  
✔ HLS C-sim + C/RTL co-sim: both testbenches PASS ([reports/hls/](reports/hls))  
✔ Tcl automation: HLS → Chisel Verilog → Vivado block design → synthesis + implementation, runnable from macOS into a Parallels Windows VM  
✔ Vivado block design (PS7 + AXI DMA + parser + OrderBook + signals), built for real — see [Synthesis results](#-synthesis-results-post-route-timing-and-utilization)  
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
│   HLS Feed Parser   │  Vitis HLS · II=22 (measured)
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
│  │  O(1) insert/delete │  │  O(1) insert/delete │  │
│  └──────────┬──────────┘  └──────────┬──────────┘  │
│             └────────────┬───────────┘             │
│                          │  BookSnapshot            │
│                imbalance · midprice · seqNum        │
└──────────────────────────┬──────────────────────────┘
                           │  AXI-Stream snapshot
                           ▼
               ┌───────────────────────┐
               │  HLS Signal Engine    │  Vitis HLS · II=1, 85-cycle depth
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

- **Deterministic single-register-stage update** — no cache misses, no branch prediction (but see the timing results below: that one stage currently contains a combinational divider)
- **Pipelined throughput** — the HLS parser accepts one message per 22 clock cycles (`reports/hls/parser_csynth.rpt`: II achieved 22, target 22). No committed csynth or cosim report measures a messages-per-second rate, and the 250 MHz clock that a rate figure would need is not met post-route, so no msg/s number is quoted here.
- **Zero-copy data path** — AXI-Stream connects all blocks without software intervention
- **Fixed, known latency** — 88 cycles from a NormMsg arriving at the book to SignalOut leaving the signal engine (about 760 ns at the ≈116 MHz the full design closes at), 111 cycles (about 960 ns) from the first raw byte. The order-book update itself is 1 cycle; the remaining ~85 cycles are the HLS signal engine's pipeline depth. Derivation in [reports/latency_derivation.md](reports/latency_derivation.md).

This mirrors the architecture used in real low-latency trading infrastructure, where the feed handler and book builder are co-located in FPGA fabric.

---

## 🚀 Performance

<p align="center">
  <img src="docs/previews/pipeline_latency.png" alt="Pipeline Latency Breakdown" width="90%" />
</p>

| Metric | Constraint / design intent | Measured (Vivado / Vitis HLS 2024.1, xc7z020clg400-1) | Evidence |
|---|---|---|---|
| Clock | 250 MHz (4.000 ns) on FCLK_CLK0 | **Constraint not met.** Setup: WNS −4.624 ns, 58 628 of 90 271 endpoints failing → setup-limited Fmax ≈ **116 MHz**. Hold: WHS +0.020 ns, 0 failing. Order book alone (OOC): setup WNS −306.218 ns, ≈ 3.2 MHz | `reports/impl/timing_summary.rpt`, `reports/ooc/N_4.000ns/timing_summary.rpt` |
| Parser initiation interval | II = 22 | **II achieved 22, target 22** (loop `VITIS_LOOP_43_1`, iteration latency 22; HLS-estimated clock 6.978 ns) | `reports/hls/parser_csynth.rpt` |
| Book update latency | 1 cycle | 1 register stage (RegNext); on its own that stage holds a 72÷42-bit combinational divide, **310 ns / 1320 logic levels** post-route | `reports/ooc/N_4.000ns/setup_paths.rpt` |
| Signal engine II | 1 | **II achieved 1, target 1** (loop `VITIS_LOOP_11_1`), iteration latency **85 cycles**; HLS-estimated clock 7.054 ns | `reports/hls/signals_csynth.rpt` |
| NormMsg → SignalOut | minimal | **88 cycles** = 1 (book) + 1 (HLS input slice) + 85 (engine) + 1 (HLS output slice) ≈ **760 ns** at ≈116 MHz; **111 cycles ≈ 960 ns** from the first raw byte; co-sim measured 86 cycles through the engine | `reports/latency_derivation.md`, `reports/hls/signals_cosim.rpt` |
| Utilization (full design, post-route) | fit in XC7Z020 | **38 814 Slice LUTs** (37 129 logic + 1 685 memory) of 53 200 = 73 %; **38 646 FFs** of 106 400 = 36 %; **2 BRAM tiles** of 140; **104 DSPs** of 220 = 47 % | `reports/impl/utilization.rpt` |
| Target device | Zynq XC7Z020 (PYNQ-Z2) | same; bitstream built, not loaded | |

The figure above is generated from the same reports (`docs/gen_visuals.py` reads `reports/hls/*_csynth.rpt` and `reports/impl/timing_summary.rpt`); nothing in it is typed in by hand.

---

## 📏 Synthesis results: post-route timing and utilization

Every number here is parsed from the committed reports in [reports/](reports) (`docs/gen_visuals.py` for the chart, the text by hand from the same files). Flow: `make vm-hls` (both HLS blocks: csim → csynth → cosim → export_ip), `make vm-ooc` (OrderBook alone, out-of-context synth + P&R at 4.000 ns), `make vm-bitstream` (the full PS7 + AXI DMA + parser + OrderBook + signal-engine block design through `write_bitstream`, FCLK_CLK0 = 250 MHz). Fmax = 1 / (period − WNS) is the setup-limited clock from post-route slack, as in the sibling cordic-engine repo.

| run | scope | Slice LUTs | FF | DSP | BRAM | period (ns) | WNS (ns) / failing | WHS (ns) / failing | constraints met | Fmax (MHz) |
|---|---|---:|---:|---:|---:|---:|---:|---:|---|---:|
| `ooc/N_4.000ns` | OrderBook alone, OOC | 7641 | 2704 | 0 | 0 | 4.000 | −306.218 / 2683 of 6750 | −0.002 / 1 | no | **3.2** |
| `impl/` | full design: PS7 + DMA + parser + book + signals, bitstream | 38814 | 38646 | 104 | 2 | 4.000 | −4.624 / 58628 of 90271 | +0.020 / 0 | no | **116** |

<p align="center">
  <img src="docs/previews/utilization.png" alt="FPGA Resource Utilization (post-route)" width="90%" />
</p>

**Reading the results.**

- **The order book does not run at 250 MHz, or at 25.** Its worst post-route path is `askStore/store_5_valid_reg` → `snap_imbalance_reg[29]`: 310 ns through 1320 logic levels (1242 CARRY4). That is `((bidVol − askVol) << 16) / totalVol` in `OrderBook.scala`, which Chisel emits as one combinational 72-bit ÷ 42-bit signed divide between the level registers and the snapshot register. The parallel-compare insert/delete logic itself is not the problem; the divider is. Moving the imbalance computation out of the Chisel book (the HLS signal engine already recomputes it with a pipelined divider) is the fix, and it has **not** been applied for these runs, so the numbers describe the design as committed.
- **The full design builds to a bitstream but does not close 250 MHz either: WNS −4.624 ns, 58 628 of 90 271 endpoints failing, setup-limited Fmax ≈ 116 MHz; hold is met (+0.020 ns).** The ten worst paths are parser → order-book register-enable paths (8.16 ns, 75 % routing) in a device that is 73 % full of LUTs, almost all of them the signal engine's dividers (33 490 of 38 814 LUTs). The book is only 2 015 LUTs here because its imbalance divider is dead logic in the integrated design — the HLS engine recomputes imbalance and never reads the book's — so Vivado removed it. That is the only reason the full design is faster than the book's own OOC run.
- **The HLS blocks meet their II targets but not the 4.000 ns clock estimate.** Vitis HLS reports II = 22 for the parser and II = 1 for the signal engine exactly as designed, with estimated clocks of 6.98 ns and 7.05 ns (≈ 140 MHz) — the parser's 103-bit constant multiply for `price_raw / TICK_SIZE` and the engine's 64-bit multiplies/divides are the long paths. The engine's II = 1 costs an 85-cycle pipeline and roughly 31 k LUTs / 61 k FFs / 88 DSPs (HLS estimate).
- **Hold.** The OOC run fails hold on one input-port path by 0.002 ns, the ideal-clock artifact of out-of-context analysis; not claimed either way.
- **Utilization (`reports/impl/utilization.rpt`).** 38 814 Slice LUTs (37 129 as logic, 1 685 as memory) of 53 200 = 73 %; 38 646 Slice Registers of 106 400 = 36 %; 2 Block RAM tiles of 140 = 1.4 %; 104 DSPs of 220 = 47 %; 4 488 CARRY4. Per block (`utilization_hierarchical.rpt`): signal engine 33 490 LUT / 32 001 FF / 88 DSP, order book 2 015 LUT / 2 642 FF, parser 253 LUT / 16 DSP, DMA + interconnects ≈ 2 600 LUT.
- **Tier 3 (hardware) has not been run.** No PYNQ-Z2 was reachable while these reports were generated, so nothing here is board-verified. Two integration gaps are known from the build alone: neither HLS stream carries `TLAST`, so the AXI DMA S2MM channel has nothing to terminate a transfer on, and `board/pynq/pynq_driver.py` unpacks 25-byte records while the HLS `SignalOut` stream is 28 bytes wide (C-struct alignment).

---

## 🚫 What IS NOT implemented

- **The 250 MHz constraint is not met.** Post-route setup WNS is −4.624 ns with 58 628 of 90 271 endpoints failing (`reports/impl/timing_summary.rpt` states "Timing constraints are not met"); the setup-limited clock is ≈ 116 MHz. Hold is met (WHS +0.020 ns, 0 failing). The order book on its own (OOC) fails setup by 306 ns because of its combinational imbalance divider and fails hold by 0.002 ns on one input-port path. Nothing in this repository closes timing at 250 MHz.
- **Never run on PYNQ-Z2 hardware.** No bitstream has been loaded onto a board, no data has been streamed over AXI DMA, and no hardware-vs-golden diff has been executed. `build/feed_handler_bd_wrapper.bit` exists only locally (gitignored) and there is no `reports/hw/`.
- **The board driver is unexercised.** `board/pynq/pynq_driver.py` has only ever run in its `pynq`-absent dry-run mode. Its 25-byte record format does not match the 28-byte HLS `SignalOut` word, and the S2MM path has no `TLAST` source, so it would need changes before a board run could complete.
- **No message-rate measurement.** II = 22 is the only throughput figure any report supports; no csynth, cosim or implementation report measures messages per second.
- **The snapshot `valid` is misaligned with the book.** `OrderBook.scala` registers the pre-update levels on the cycle `valid` rises (see `reports/latency_derivation.md`); the tests pass because they sample two cycles later. Not fixed.
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
Six test cases exercise the Chisel order book directly: sorted bid insert, sorted ask insert, level deletion, in-place size update, imbalance sign, midprice arithmetic, and depth-cap enforcement.

**Level 2 — HLS C-sim + Co-sim**  
Each HLS block has a standalone C++ testbench. Co-simulation re-runs the same testbench against Verilog-level RTL after synthesis to confirm functional equivalence. Both pass (`parser_tb PASSED`, `signals_tb PASSED`, `C/RTL co-simulation finished: PASS`); the `*_cosim.rpt` tables show `Status Fail` alongside, which the HLS log attributes to the `ap_ctrl_none` + non-blocking `while (!stream.empty())` structure (`COSIM 212-382`) — see [reports/latency_derivation.md](reports/latency_derivation.md).

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
- `PriceLevelStore.scala` — single-sided parallel-compare sorted store; O(1) insert/update/delete; parametric depth, price bits, size bits; isBid flag controls sort direction
- `OrderBook.scala` — top-level module; AXI-Stream slave input; routes to bid/ask stores; computes imbalance (Q16), midprice; registered output snapshot; emits Verilog via `OrderBookVerilog` app object

### HLS Parser (`hls/parser/`)
- 22-byte little-endian wire format: `{msg_type, side, seq_num, price_raw, size_raw}`
- Price normalized to ticks via compile-time `TICK_SIZE` constant
- Delete messages (`'D'`) emit `size=0` to signal level removal to the book
- Unknown message types dropped silently

### HLS Signal Engine (`hls/signals/`)
- Receives `BookSnapshot` structs from the order book
- Computes all six signals in a single II=1 pipelined loop with `#pragma HLS UNROLL` across depth slots
- VWAP uses Q8 fixed-point to avoid floating-point in the fabric

### Tcl Automation (`tcl/`)
- `run_hls_parser.tcl` / `run_hls_signals.tcl` — full HLS flow: csim → csynth → cosim → IP export
- `vivado_project.tcl` — creates the Vivado project, adds the HLS IPs and `OrderBook.v`, builds the block design, runs synthesis + implementation to a bitstream, writes `reports/impl/*.rpt`
- `block_design.tcl` — PS7 (FCLK_CLK0 constrained to 250 MHz; not met post-route) + AXI DMA (8-bit streams) → parser → OrderBook (via `rtl/orderbook_axis_wrap.v`) → signals → AXIS width converter → DMA
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
│   └── latency_derivation.md         NormMsg -> SignalOut cycle accounting (88 / 111 cycles)
└── constraints/pynq_z2.xdc
```

---

## 📜 License

MIT License — see [LICENSE](LICENSE) for details.
