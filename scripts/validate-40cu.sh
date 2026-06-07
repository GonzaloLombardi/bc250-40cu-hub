#!/usr/bin/env bash
# validate-40cu.sh — verify all 40 CUs are routed on a BC-250 via the runtime-UMR method.
#
# Default: register-level check (definitive). Add --bench for a compute throughput check.
# Run with sudo (umr needs root).
#
#   sudo ./validate-40cu.sh
#   sudo ./validate-40cu.sh --bench
set -uo pipefail

ASIC="cyan_skillfish.gfx1013"
REG_SPI="mmSPI_PG_ENABLE_STATIC_WGP_MASK"
REG_CC="mmCC_GC_SHADER_ARRAY_CONFIG"
WANT_SPI="0x0000001f"   # all 5 WGPs routed (stock = 0x07)
WANT_CC="0xffe00000"    # harvest mask cleared (stock = 0xfff80000)
MGR="${MGR:-/usr/local/bin/bc250-cu-live-manager}"
RUN_BENCH=0
[ "${1:-}" = "--bench" ] && RUN_BENCH=1

[ "$(id -u)" = "0" ] || { echo "run with sudo (umr needs root)"; exit 2; }
command -v umr >/dev/null 2>&1 || { echo "umr not found — install it first"; exit 2; }

# Auto-detect the BC-250 DRI instance (the number is NOT stable across boots).
BDF="$(lspci -Dn 2>/dev/null | grep -i '1002:13fe' | awk '{print $1}' | head -1)"
INST=""
# Prefer the tool's own detection if it's installed.
[ -x "$MGR" ] && INST="$("$MGR" status 2>/dev/null | grep 'UMR inst' | grep -oE '[0-9]+' | head -1)"
# Fallback: scan debugfs, matching the BDF. Only purely-numeric dirs < 128 are umr
# instances (skip the BDF-named dir like 0000:01:00.0 and render nodes 128+).
if [ -z "$INST" ] && [ -n "$BDF" ]; then
  for d in /sys/kernel/debug/dri/[0-9]*; do
    inst="${d##*/}"
    [[ "$inst" =~ ^[0-9]+$ ]] || continue
    [ "$inst" -lt 128 ] || continue
    [ -e "$d/name" ] || continue
    if grep -q "$BDF" "$d/name" 2>/dev/null; then INST="$inst"; break; fi
  done
fi
IARG=(); [ -n "$INST" ] && IARG=(-i "$INST")
echo "BC-250 BDF: ${BDF:-?}   DRI instance: ${INST:-default}"
echo

# Register check, per shader array (SE/SH).
ok=1
printf '%-9s %-12s %-12s %s\n' "Row" "SPI" "CC" "Result"
for se in 0 1; do for sh in 0 1; do
  spi="$(umr "${IARG[@]}" -r "$ASIC.$REG_SPI" -b "$se" "$sh" 0xffffffff 2>/dev/null | grep -oE '0x[0-9a-f]{8}' | head -1)"
  cc="$(umr "${IARG[@]}" -r "$ASIC.$REG_CC"  -b "$se" "$sh" 0xffffffff 2>/dev/null | grep -oE '0x[0-9a-f]{8}' | head -1)"
  if [ "$spi" = "$WANT_SPI" ] && [ "$cc" = "$WANT_CC" ]; then res="ok"; else res="MISMATCH"; ok=0; fi
  printf 'SE%s.SH%s   %-12s %-12s %s\n' "$se" "$sh" "${spi:-?}" "${cc:-?}" "$res"
done; done

echo
if [ "$ok" = 1 ]; then
  echo "REGISTER CHECK: PASS — all 4 shader arrays at 0x1f / 0xffe00000  => 40/40 CUs routed"
else
  echo "REGISTER CHECK: FAIL — expected SPI=$WANT_SPI CC=$WANT_CC on every row"
fi

acn="$(dmesg 2>/dev/null | grep -o 'active_cu_number [0-9]*' | tail -1 | grep -oE '[0-9]+')"
echo "driver active_cu_number = ${acn:-?}  (stays 24 with runtime-UMR — expected, NOT a failure)"

if [ "$RUN_BENCH" = 1 ]; then
  echo
  echo "=== compute check (pp512) ==="
  uh="$(getent passwd "${SUDO_USER:-root}" | cut -d: -f6)"; [ -n "$uh" ] || uh="$HOME"
  BIN="$(find "$uh/llamabench" /root/llamabench -name llama-bench 2>/dev/null | head -1)"
  MODEL="$(ls "$uh"/models/*.gguf /root/models/*.gguf 2>/dev/null | head -1)"
  if [ -n "$BIN" ] && [ -n "$MODEL" ]; then
    LD_LIBRARY_PATH="$(dirname "$BIN")" "$BIN" -m "$MODEL" -p 512 -n 0 -ngl 99 -r 2 2>/dev/null | grep -E 'pp512'
    echo "(~1060 t/s ≈ 40 CU, ~680 t/s ≈ 24 CU on Qwen2.5-3B Q4 — the jump only happens if the extra CUs compute)"
  else
    echo "skipped: llama-bench or a .gguf model not found under $uh"
  fi
fi

[ "$ok" = 1 ] && exit 0 || exit 1
