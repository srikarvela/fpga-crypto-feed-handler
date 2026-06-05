# fpga-crypto-feed-handler master Makefile
# Targets map to the three build tiers.

VITIS_HLS ?= vitis_hls
VIVADO    ?= vivado
SBT       ?= sbt

# ── Tier 1: simulation ────────────────────────────────────────────────────────

.PHONY: chisel-test
chisel-test:
	cd chisel && $(SBT) test

.PHONY: chisel-verilog
chisel-verilog:
	cd chisel && $(SBT) --batch "runMain orderbook.OrderBookVerilog"

.PHONY: hls-parser
hls-parser:
	$(VITIS_HLS) -f tcl/run_hls_parser.tcl

.PHONY: hls-signals
hls-signals:
	$(VITIS_HLS) -f tcl/run_hls_signals.tcl

.PHONY: golden-test
golden-test:
	cd python/golden && python -m pytest test_golden.py -v

.PHONY: sim
sim: chisel-test hls-parser hls-signals golden-test
	@echo "=== Tier 1 simulation complete ==="

# ── Tier 2: synthesis ─────────────────────────────────────────────────────────

.PHONY: synth
synth: chisel-verilog
	$(VIVADO) -mode batch -source tcl/vivado_project.tcl
	@echo "=== Timing report: vivado/timing_summary.rpt ==="
	@echo "=== Utilization:   vivado/utilization.rpt    ==="

# ── Tier 3: on-board ─────────────────────────────────────────────────────────

.PHONY: capture
capture:
	python python/feed/coinbase_feed.py python/vectors/btcusd_snapshot.bin 5000

.PHONY: golden
golden:
	python python/golden/order_book_ref.py \
		python/vectors/btcusd_snapshot.bin \
		python/vectors/golden_snaps.json

.PHONY: board-run
board-run:
	ssh xilinx@pynq "python3 ~/fpga_crypto_feed/pynq_driver.py \
		~/fpga_crypto_feed/btcusd_snapshot.bin \
		~/fpga_crypto_feed/golden_snaps.json"

# ── Clean ─────────────────────────────────────────────────────────────────────

.PHONY: clean
clean:
	rm -rf chisel/generated chisel/target chisel/project/target
	rm -rf feed_parser compute_signals
	rm -rf vivado
	rm -f python/vectors/*.bin python/vectors/*.json

.PHONY: all
all: sim synth
