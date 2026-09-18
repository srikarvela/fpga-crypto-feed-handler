#!/usr/bin/env bash
# Run the Vitis HLS / Vivado flows inside a Parallels Windows VM from macOS
# (Apple Silicon hosts can't run the AMD tools natively) and copy the reports
# back into reports/ (committed) and build/ (gitignored).
# Adapted from cordic-engine/scripts/vivado_in_parallels.sh.
#
#   ./scripts/vivado_in_parallels.sh hls         # csim -> csynth -> cosim -> export_ip, parser + signals
#   ./scripts/vivado_in_parallels.sh ooc         # OrderBook alone, out-of-context synth + P&R at 4.000 ns
#   ./scripts/vivado_in_parallels.sh bitstream   # project + block design -> synth -> impl -> bitstream
#
# The working tree (hls/, tcl/, constraints/, rtl/, chisel/generated/ -- no
# commit needed; run `make chisel-verilog` first) is zipped into a folder the
# VM sees through Parallels shared folders and unzipped to a local VM disk.
# `hls` starts from a clean VM work dir; `ooc`/`bitstream` unzip on top of it so
# the exported HLS IP from the `hls` step is still there for the block design.
#
# Vivado under x86 emulation intermittently fails to read its own data files
# while creating a block design ("couldn't read file ...", "find_approot_file
# ... init.tcl"); those runs are retried, any other failure stops the script.
#
# Environment overrides:
#   FEED_VM          Parallels VM name             (default "Windows 11")
#   FEED_VIVADO      vivado.bat inside the VM      (default C:\Xilinx\Vivado\2024.1\bin\vivado.bat)
#   FEED_VITIS_HLS   vitis_hls.bat inside the VM   (default C:\Xilinx\Vitis_HLS\2024.1\bin\vitis_hls.bat)
#   FEED_VM_WORKDIR  build directory inside the VM (default C:\feed)
#   FEED_SHARE_MAC   macOS side of a shared folder (default ~/Downloads/feed-vm-transfer)
#   FEED_SHARE_VM    same folder as the VM sees it (default Z:\Downloads\feed-vm-transfer)
#   FEED_TRIES       attempts per Vivado run       (default 4)
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-bitstream}"
VM="${FEED_VM:-Windows 11}"
VIVADO="${FEED_VIVADO:-C:\\Xilinx\\Vivado\\2024.1\\bin\\vivado.bat}"
VITIS_HLS="${FEED_VITIS_HLS:-C:\\Xilinx\\Vitis_HLS\\2024.1\\bin\\vitis_hls.bat}"
WORK="${FEED_VM_WORKDIR:-C:\\feed}"
SHARE_MAC="${FEED_SHARE_MAC:-$HOME/Downloads/feed-vm-transfer}"
SHARE_VM="${FEED_SHARE_VM:-Z:\\Downloads\\feed-vm-transfer}"
TRIES="${FEED_TRIES:-4}"

case "$MODE" in hls|ooc|bitstream) ;; *) echo "usage: $0 hls|ooc|bitstream"; exit 2 ;; esac
[ "$MODE" = hls ] || [ -f chisel/generated/OrderBook.v ] || { echo "chisel/generated/OrderBook.v missing: run 'make chisel-verilog' first"; exit 1; }
command -v prlctl >/dev/null || { echo "prlctl not found (Parallels Desktop Pro/Business required)"; exit 1; }
state="$(prlctl list -a -o status,name | awk -v vm="$VM" '$0 ~ vm {print $1}')"
case "$state" in
  running)   ;;
  suspended) echo "resuming VM '$VM'"; prlctl resume "$VM" >/dev/null ;;
  stopped)   echo "starting VM '$VM'"; prlctl start  "$VM" >/dev/null ;;
  paused)    prlctl unpause "$VM" >/dev/null ;;
  *) echo "Parallels VM '$VM' not found (set FEED_VM)"; exit 1 ;;
esac

vm() { prlctl exec "$VM" --current-user "$@"; }
for _ in $(seq 1 30); do vm cmd /c "echo ready" >/dev/null 2>&1 && break; sleep 5; done

mkdir -p "$SHARE_MAC" reports build
rm -rf "$SHARE_MAC/out" "$SHARE_MAC/feed.zip"
zip -qr "$SHARE_MAC/feed.zip" hls tcl constraints rtl chisel/generated -x 'chisel/generated/*.fir' 'chisel/generated/*.json'
if [ "$MODE" = hls ]; then
  vm powershell -NoProfile -Command "Remove-Item -Recurse -Force '$WORK' -ErrorAction SilentlyContinue; Expand-Archive -Path '$SHARE_VM\\feed.zip' -DestinationPath '$WORK'" >/dev/null
else
  vm powershell -NoProfile -Command "Expand-Archive -Force -Path '$SHARE_VM\\feed.zip' -DestinationPath '$WORK'" >/dev/null
fi
vm cmd /c "mkdir \"$WORK\\reports\" 2>nul & mkdir \"$WORK\\build\" 2>nul & rmdir /s /q \"$WORK\\vivado\" 2>nul & echo." >/dev/null || true
echo "Copied working tree to $VM:$WORK ($MODE)"

collect() {  # copy WORK\reports and WORK\build back through the share
  vm cmd /c "mkdir \"$SHARE_VM\\out\" 2>nul & xcopy /e /y /i /q \"$WORK\\reports\" \"$SHARE_VM\\out\\reports\" >nul & xcopy /e /y /i /q \"$WORK\\build\" \"$SHARE_VM\\out\\build\" >nul" || true
  cp -R "$SHARE_MAC/out/reports/." reports/ 2>/dev/null || true
  cp -R "$SHARE_MAC/out/build/." build/ 2>/dev/null || true
}

status=0
if [ "$MODE" = hls ]; then
  for blk in parser signals; do
    case $blk in parser) proj=feed_parser ;; signals) proj=compute_signals ;; esac
    log="vitis_hls_${blk}.log"
    echo "== Vitis HLS $proj: csim -> csynth -> cosim -> export_ip (log: build/$log)"
    # `< nul`: on Windows vitis_hls -f drops into its interactive prompt after the script instead of exiting
    vm cmd /c "cd /d $WORK && \"$VITIS_HLS\" -f tcl/run_hls_${blk}.tcl < nul > build\\$log 2>&1" || true
    # committed: the csynth + cosim reports; local: the whole solution report dirs and the generated RTL
    vm cmd /c "cd /d $WORK && mkdir reports\\hls 2>nul & mkdir build\\hls\\$proj 2>nul & copy /y $proj\\solution1\\syn\\report\\${proj}_csynth.rpt reports\\hls\\${blk}_csynth.rpt >nul & copy /y $proj\\solution1\\sim\\report\\${proj}_cosim.rpt reports\\hls\\${blk}_cosim.rpt >nul & xcopy /e /y /i /q $proj\\solution1\\syn\\report build\\hls\\$proj\\syn_report >nul & xcopy /e /y /i /q $proj\\solution1\\sim\\report build\\hls\\$proj\\sim_report >nul & xcopy /e /y /i /q $proj\\solution1\\impl\\verilog build\\hls\\$proj\\verilog >nul & copy /y $proj\\solution1\\impl\\ip\\component.xml build\\hls\\$proj\\ >nul" || true
    collect
    grep -E "^ERROR|PASSED|FAILED|C/RTL co-simulation|Exporting" "build/$log" | head -12 || true
    if ! grep -q "=== $proj HLS flow complete ===" "build/$log" 2>/dev/null; then echo "-- $proj HLS flow did not complete (see build/$log)"; status=1; fi
  done
else
  case "$MODE" in
    ooc)       TCL="tcl/orderbook_ooc.tcl"; DONE="=== OrderBook OOC" ;;
    bitstream) TCL="tcl/vivado_project.tcl"; DONE="=== Vivado implementation complete" ;;
  esac
  status=1
  for i in $(seq 1 "$TRIES"); do
    log="vivado_${MODE}_try$i.log"
    echo "== Vivado $MODE, attempt $i/$TRIES (log: build/$log)"
    vm cmd /c "cd /d $WORK && rmdir /s /q vivado 2>nul & \"$VIVADO\" -mode batch -nolog -nojournal -source $TCL > build\\$log 2>&1" || true
    collect
    grep -E "^ERROR|CRITICAL WARNING|^=== " "build/$log" | head -20 || true
    if grep -q "$DONE" "build/$log" 2>/dev/null; then status=0; break; fi
    if grep -qE "couldn't read file|find_approot_file|invalid command name \"::xgui" "build/$log" 2>/dev/null; then
      echo "-- flaky Vivado data-file read under emulation, retrying"; continue
    fi
    echo "-- Vivado $MODE failed (see build/$log)"; break
  done
fi

rm -rf "$SHARE_MAC"
[ "$status" -eq 0 ] && echo "Done ($MODE): see reports/ and build/"
exit "$status"
