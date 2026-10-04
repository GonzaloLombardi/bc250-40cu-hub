#!/usr/bin/env bash
# undervolt-test.sh — find how far a clock can be undervolted WITHOUT silent compute errors.
#
# Holds a frequency/voltage pair through the governor's root-only D-Bus TestMode (no config
# edits; throttling stays active), then at each step checks:
#   - pp512 throughput and package power / temp under load,
#   - amdgpu errors in dmesg,
#   - that a deterministic llama.cpp generation (temp 0, fixed seed) still produces the SAME
#     text as at the stock voltage. This catches silent miscompute: on our board 890 mV at
#     1850 MHz benchmarked normally with a clean dmesg but produced different output.
# Stops at the first failure and restarts the governor (back to adaptive) on exit.
#
#   sudo -v && ./undervolt-test.sh                         # 1850 MHz: 930 910 890 870 850 mV
#   FREQ=1700 VOLTS="920 900 880" ./undervolt-test.sh
#
# Needs cyan-skillfish-governor-smu (dbus enabled), sudo, and llama.cpp (llama-bench +
# llama-completion) + a .gguf model under ~/llamabench and ~/models (see the unlock guide).
# A passing step is NOT a stability guarantee: re-test the value you keep, and leave margin.
set -u
F=${FREQ:-1850}; VOLTS=${VOLTS:-"930 910 890 870 850"}
G=""; for h in /sys/class/hwmon/hwmon*; do [ "$(cat $h/name)" = amdgpu ] && G=$h; done
B=$(find ~/llamabench -name llama-bench | head -1); D=$(dirname "$B")
M=${MODEL:-$(ls ~/models/*.gguf 2>/dev/null | head -1)}
[ -n "$G" ] && [ -x "$D/llama-completion" ] && [ -n "$M" ] || { echo "need amdgpu hwmon, llama-bench + llama-completion, and a model"; exit 2; }
PROMPT="Explain in detail how a GPU executes a compute shader, step by step:"
gen() { LD_LIBRARY_PATH=$D timeout 120 "$D/llama-completion" -m "$M" -p "$PROMPT" -n 160 --temp 0 --seed 1 -ngl 99 -no-cnv 2>/dev/null </dev/null | sha256sum | cut -d" " -f1; }
cool() { sudo systemctl restart cyan-skillfish-governor-smu; local i=0; while [ $(( $(cat $G/temp1_input)/1000 )) -gt 62 ] && [ $i -lt 24 ]; do sleep 5; i=$((i+1)); done; }
trap 'sudo systemctl restart cyan-skillfish-governor-smu; echo "governor restarted (adaptive)"' EXIT

# Reference output at stock (adaptive governor, shipped voltages). Must be reproducible.
cool; REF=$(gen); [ "$REF" = "$(gen)" ] || { echo "reference generation is not reproducible; aborting"; exit 2; }
echo "reference: ${REF:0:16}…  (freq $F MHz)"

printf "%-5s %-9s %-8s %-8s %-8s %-8s %s\n" mV pp512 vdd_avg T_avg T_peak P_avg check
for V in $VOLTS; do
  cool; sudo dmesg -C
  sudo busctl --system call com.cyanskillfish.Governor /com/cyanskillfish/Governor \
    com.cyanskillfish.Governor.TestMode SetTestMode uu "$F" "$V" || { echo "SetTestMode failed at $V"; exit 1; }
  sleep 3
  S=$(mktemp); ( while :; do echo "$(cat $G/in0_input) $(cat $G/temp1_input) $(cat $G/power1_input)"; sleep 0.5; done ) > "$S" & SP=$!
  R=$(LD_LIBRARY_PATH=$D timeout 300 "$B" -m "$M" -p 512 -n 0 -ngl 99 -r 10 2>/dev/null | awk -F'|' '/pp512/{print $(NF-1)}' | grep -oE '[0-9]+\.[0-9]+' | head -1)
  kill $SP; wait $SP 2>/dev/null
  H1=$(gen); H2=$(gen)
  ERR=$(sudo dmesg | grep -ciE "amdgpu.*(error|fault|reset|timeout|hang)|ring .* timeout|GPU recovery")
  OK=ok; { [ "$H1" = "$REF" ] && [ "$H2" = "$REF" ]; } || OK="OUTPUT MISMATCH"
  [ -n "$R" ] || OK="BENCH FAILED"; [ "$ERR" -eq 0 ] || OK="DMESG ERRORS ($ERR)"
  awk -v V="$V" -v R="${R:-?}" -v C="$OK" '{if($3>m)m=$3; a[NR]=$0} END{for(i=1;i<=NR;i++){split(a[i],x," "); if(x[3]>0.6*m){n++;v+=x[1];t+=x[2];p+=x[3]; if(x[2]>tm)tm=x[2]}} printf "%-5s %-9s %-8d %-8.1f %-8.1f %-8.1f %s\n",V,R,v/n,t/n/1000,tm/1000,p/n/1e6,C}' "$S"; rm -f "$S"
  [ "$OK" = ok ] || { echo "stopping: instability at $V mV"; exit 3; }
done
