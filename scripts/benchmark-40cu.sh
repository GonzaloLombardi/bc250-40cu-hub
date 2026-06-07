#!/usr/bin/env bash
# benchmark-40cu.sh — A/B compute proof for the BC-250 unlock.
# Measures pp512 throughput at 40 CU vs 24 CU and reports the speedup. The jump only
# happens if the 16 unlocked CUs actually do work, so a ~1.5x ratio confirms the unlock.
#
#   sudo ./benchmark-40cu.sh
#
# Needs the runtime-UMR tool installed and a llama.cpp Vulkan llama-bench + a .gguf model
# (see the unlock guide). Restores 40 CU on exit. Run with sudo.
set -uo pipefail

MGR="${MGR:-/usr/local/bin/bc250-cu-live-manager}"
REPS="${REPS:-3}"
[ "$(id -u)" = "0" ] || { echo "run with sudo"; exit 2; }
[ -x "$MGR" ] || { echo "$MGR not found"; exit 2; }

uh="$(getent passwd "${SUDO_USER:-root}" | cut -d: -f6)"; [ -n "$uh" ] || uh="$HOME"
BIN="$(find "$uh/llamabench" /root/llamabench -name llama-bench 2>/dev/null | head -1)"
MODEL="$(ls "$uh"/models/*.gguf /root/models/*.gguf 2>/dev/null | head -1)"
[ -n "$BIN" ] && [ -n "$MODEL" ] || { echo "need llama-bench + a .gguf model (see the unlock guide)"; exit 2; }
LIB="$(dirname "$BIN")"

# amdgpu hwmon for a temp readout (numbering can change across boots)
HW=""; for h in /sys/class/hwmon/hwmon*; do grep -qi amdgpu "$h/name" 2>/dev/null && HW="$h"; done
temp() { [ -n "$HW" ] && echo " ($(($(cat "$HW/temp1_input")/1000))C)"; }

run() {
  LD_LIBRARY_PATH="$LIB" "$BIN" -m "$MODEL" -p 512 -n 0 -ngl 99 -r "$REPS" 2>/dev/null \
    | awk -F'|' '/pp512/{print $(NF-1)}' | grep -oE '[0-9]+\.[0-9]+' | head -1
}

# Always leave the board at 40 CU, even on Ctrl-C.
trap '"$MGR" enable all --yes >/dev/null 2>&1' EXIT

echo "model: $(basename "$MODEL")   reps: $REPS"
echo "measuring 40 CU ..."
"$MGR" enable all --yes >/dev/null 2>&1
t40="$(run)"; echo "  40 CU: ${t40:-?} tok/s$(temp)"

echo "measuring 24 CU (stock) ..."
"$MGR" stock-dispatch --yes >/dev/null 2>&1
t24="$(run)"; echo "  24 CU: ${t24:-?} tok/s$(temp)"

"$MGR" enable all --yes >/dev/null 2>&1
echo "restored to 40 CU"
echo

if [ -n "$t40" ] && [ -n "$t24" ]; then
  ratio="$(awk -v a="$t40" -v b="$t24" 'BEGIN{ if(b>0) printf "%.2f", a/b; else print "0" }')"
  echo "pp512 speedup  40CU / 24CU = ${ratio}x"
  awk -v r="$ratio" 'BEGIN{
    if (r+0 >= 1.30) { print "RESULT: PASS — the 16 unlocked CUs are doing real compute work"; exit 0 }
    else if (r+0 >= 1.05) { print "RESULT: WEAK — some gain but below ~1.5x; suspect thermal throttling, check cooling/clocks"; exit 1 }
    else { print "RESULT: FAIL — no meaningful gain; the extra CUs are not contributing"; exit 1 }
  }'
else
  echo "could not parse benchmark output"; exit 1
fi
