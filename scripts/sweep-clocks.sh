#!/usr/bin/env bash
# sweep-clocks.sh — GPU frequency sweep at 40 CU, as used for the governor-tuning table.
# Pins each clock through the governor's D-Bus helper (no config edits, throttling stays on),
# runs llama-bench pp512, and samples temp / power / vddgfx / sclk every 0.5 s DURING the load.
# Between points it cools down in adaptive mode (a pinned clock stays high even at idle).
#
#   ./sweep-clocks.sh                       # 1500 1700 1850 2000 MHz
#   FREQS="1600 1800" ./sweep-clocks.sh
#
# Needs cyan-skillfish-governor-smu with [dbus] enabled = true (no root needed), and a llama.cpp
# Vulkan llama-bench + model under ~/llamabench and ~/models (see the unlock guide).
# Restores adaptive mode on exit.
set -u
HW=""; for h in /sys/class/hwmon/hwmon*; do [ "$(cat $h/name)" = amdgpu ] && HW=$h; done
B=$(find ~/llamabench -name llama-bench | head -1); L=$(dirname "$B")
M=${MODEL:-$(ls ~/models/*.gguf 2>/dev/null | head -1)}
tC() { echo $(( $(cat $HW/temp1_input)/1000 )); }
# Cool down in adaptive mode (pinning holds the clock high even at idle): <=62C or 120 s max.
cool() { cyan-skillfish-performance-mode --off >/dev/null; local i=0; while [ "$(tC)" -gt 62 ] && [ $i -lt 24 ]; do sleep 5; i=$((i+1)); done; }
trap 'cyan-skillfish-performance-mode --off >/dev/null' EXIT
printf "%-6s %-9s %-9s %-9s %-8s %-8s %-8s %-9s %s\n" MHz pp512 sclk_avg vdd_avg T_avg T_peak P_avg P_peak T_start
for F in ${FREQS:-1500 1700 1850 2000}; do
  cool; T0=$(tC)
  cyan-skillfish-performance-mode --fixed-frequency "$F" >/dev/null; sleep 3
  SMP=$(mktemp)
  ( while :; do echo "$(cat $HW/freq1_input) $(cat $HW/in0_input) $(cat $HW/temp1_input) $(cat $HW/power1_input)"; sleep 0.5; done ) > "$SMP" &
  SP=$!
  R=$(LD_LIBRARY_PATH=$L "$B" -m $M -p 512 -n 0 -ngl 99 -r 10 2>/dev/null | awk -F'|' '/pp512/{print $(NF-1)}' | grep -oE '[0-9]+\.[0-9]+' | head -1)
  kill $SP; wait $SP 2>/dev/null
  awk -v F="$F" -v R="$R" -v T0="$T0" '{f[NR]=$1;v[NR]=$2;t[NR]=$3;p[NR]=$4; if($4>pm)pm=$4}
    END{for(i=1;i<=NR;i++) if(p[i]>0.6*pm){n++;sf+=f[i];sv+=v[i];st+=t[i];sp+=p[i]; if(t[i]>tm)tm=t[i]}
    printf "%-6s %-9s %-9d %-9d %-8.1f %-8.1f %-8.1f %-9.1f %s\n",F,R,sf/n/1e6,sv/n,st/n/1000,tm/1000,sp/n/1e6,pm/1e6,T0}' "$SMP"
  rm -f "$SMP"
done
