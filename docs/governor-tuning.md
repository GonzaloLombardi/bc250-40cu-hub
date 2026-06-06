# Governor & clock/voltage tuning on the BC-250 (cyan-skillfish-governor-smu)

The BC-250 has no usable stock power management on Linux — you run a userspace **governor**
that drives the SMU to set GPU frequency/voltage based on load. The de-facto choice on
Bazzite/Fedora is **[filippor/cyan-skillfish-governor](https://github.com/filippor/cyan-skillfish-governor)**
(SMU branch), packaged as `cyan-skillfish-governor-smu`.

> ← Back to the [hub README](../README.md). Pair this with the
> [40 CU unlock guide](bazzite-40cu-runtime-umr.md) — the numbers below are at **40 CU**.

---

## Install / status

```bash
sudo dnf copr enable filippor/bazzite      # or rpm-ostree on atomic, then reboot
rpm-ostree install cyan-skillfish-governor-smu   # Bazzite (atomic) — reboot after
sudo systemctl enable --now cyan-skillfish-governor-smu.service
systemctl is-active cyan-skillfish-governor-smu
```

Config: **`/etc/cyan-skillfish-governor-smu/config.toml`** (world-readable). Apply changes
with `sudo systemctl restart cyan-skillfish-governor-smu`.

---

## Understanding `config.toml`

```toml
[gpu]
set-method = "smu"     # "smu" (drive the SMU directly) or "kernel"

[frequency-range]
min = 1000    # MHz — floor
max = 1850    # MHz — ceiling (the governor never exceeds this)

[load-target]
upper = 0.65  # ramp up above 65% busy
lower = 0.50  # ramp down below 50% busy

[temperature]
throttling = 85           # °C — hard safety: clock down when hit
throttling_recovery = 75  # °C — resume when back under

# Frequency → voltage table. The governor only runs at these (freq, voltage) pairs.
[[safe-points]]
frequency = 1500
voltage = 900
[[safe-points]]
frequency = 1700
voltage = 920
[[safe-points]]
frequency = 1850
voltage = 930
# ... up to 2000 / 960
```

Key ideas:
- **`safe-points`** are the only allowed operating points; each maps a frequency to the
  voltage the governor will request for it. Lowering a point's `voltage` = undervolt
  (cooler/less power, but unstable if too aggressive).
- **`frequency-range.max`** is your real ceiling. Raising it lets the governor reach higher
  safe-points under load.
- **`temperature.throttling`** is the safety net — leave it on (85 °C is sane) even while
  experimenting. Until the governor *service* is enabled, any crash reboots to stock clocks.

---

## Measured sweep (40 CU, Bazzite 44)

Each frequency was **pinned** (`min = max = F`), then `llama-bench -p 512` (Qwen2.5-3B
Q4_K_M) was run at 40 CU. Temp/power are post-run steady state.

| Freq cap | pp512 (tok/s) | Voltage | Temp | Power | Notes |
|---|---|---|---|---|---|
| 1500 MHz | 873 | 837 mV* | 53 °C | 53 W | efficient/cool |
| 1700 MHz | 983 | 912 mV | 57 °C | 64 W | **sweet spot** |
| 1850 MHz | 1062 | 918 mV | 60 °C | 80 W | balanced |
| **2000 MHz** | **1144** | 960 mV | **73 °C peak** ‡ | ~161 W peak ‡ | **held full clock, no throttle** ‡ |

\* observed SMU voltage at that point on this board.

‡ The 2000 MHz row was measured **live with a temp watchdog** (peak sampling), so its temp/power
are *transient peaks* under load; the 1500–1850 rows show *post-run steady* values, so the power
columns aren't directly comparable (the same 2000 MHz run that peaked at 161 W read ~71 W moments
after it finished). On **this board's cooling** it held a flat 2000 MHz with **no throttling and
only 73 °C** — but that number is the single most cooling-dependent figure in this whole doc
(see the ❄️ note below).

> ### ❄️ Everything here is cooling-dependent
>
> These temps reflect **one specific board + cooling setup**. The BC-250's thermals vary
> enormously with airflow, heatsink/fan, paste, ambient, and case. A board that hits 73 °C at
> 2000 MHz on good cooling can hit **90–96 °C** (community-reported) on weak cooling — same
> registers, same clocks. **Treat the numbers above as *your* potential ceiling only after you
> measure your own board.** Improving cooling is usually the highest-leverage change: it's what
> turns "2000 MHz throttles/crashes" into "2000 MHz runs cool." Always keep `throttling = 85`
> on and watch temps live the first time you push clocks.

**Takeaways:**
- Throughput scales **almost linearly** with frequency (1500 → 1850 MHz: +23% clock → +22%
  tok/s).
- **Power scales faster than performance.** The 1700 → 1850 step buys ~+8% throughput for
  ~+25% power (64 → 80 W). **1700 MHz is the efficiency sweet spot.**
- All well within thermal limits with the 40 CU unlock active across the whole range:
  ≤ 60 °C up to 1850 MHz, and **73 °C peak even at a sustained 2000 MHz** on this board.
- **2000 MHz held full clock with no throttling here** and is the top safe-point in the
  default config — but heat/power climb steeply (peak ~161 W) and the temp is heavily
  cooling-dependent. The decision is yours (see below).

> Note: combine this with the unlock — at a *fixed* clock, going 24 → 40 CU is the larger
> win (≈1.55× from the [unlock benchmark](bazzite-40cu-runtime-umr.md#step-5--verify-it-does-real-work-benchmark));
> clock tuning is the second-order knob on top.

---

## How to pin a frequency for benchmarking

The governor is load-adaptive, so to measure a single clock cleanly, set `min = max`:

```bash
sudo sed -i 's/^\s*min = .*/min = 1700/; s/^\s*max = .*/max = 1700/' \
  /etc/cyan-skillfish-governor-smu/config.toml
sudo systemctl restart cyan-skillfish-governor-smu
cat /sys/class/hwmon/hwmon*/freq1_input   # confirm it's holding (Hz)
```

Restore your range (e.g. `min = 1000`, `max = 1850`) and restart when done. Watch live:

```bash
HW=$(for h in /sys/class/hwmon/hwmon*; do grep -qi amdgpu "$h/name" && echo "$h"; done)
watch -n1 'echo "$(($(cat '"$HW"'/temp1_input)/1000))C $(($(cat '"$HW"'/power1_average)/1000000))W $(($(cat '"$HW"'/freq1_input)/1000000))MHz"'
```

---

## Going to 2000 MHz (the top safe-point)

The default config already ships a `2000 MHz / 960 mV` safe-point — the unlock doesn't cap
your clocks, so **whether to use it is entirely your decision**. It's the highest-throughput
setting (**1144 tok/s here, ~1.08× over 1850 MHz**), at the cost of meaningfully more heat and
power (peak ~161 W). On the test board's cooling it held a flat 2000 MHz with **no throttling
at 73 °C peak** — but community boards with weaker cooling report **~90–96 °C** at this exact
setting. Same registers, wildly different temps: it's a "know your cooling + monitor" setting,
not fire-and-forget.

To raise the ceiling so the governor can reach 2000 MHz under load:

```bash
sudo sed -i 's/^\s*max = .*/max = 2000/' /etc/cyan-skillfish-governor-smu/config.toml
sudo systemctl restart cyan-skillfish-governor-smu
```

Then **stress-test while watching temps live** (use the `watch` one-liner above, or the
`llama-bench` loop from the unlock guide). The `throttling = 85` line is your safety net — it
will clock down before things get dangerous. Recommended checks before keeping it:

- Temp stays below your comfort threshold under sustained load (the 85 °C throttle is a
  ceiling, not a target — many prefer to keep peaks in the low 80s).
- No GPU resets/crashes in `dmesg` during a stress run.
- If unstable, either drop `max` back to 1850, or nudge the 2000 MHz safe-point's `voltage`
  up a touch (e.g. 960 → 970 mV) for more headroom.

Revert anytime: set `max` back to `1850` (or `1700`) and restart the service.

## Recommended starting point

- **Efficiency:** `max = 1700` (the measured sweet spot) — coolest/quietest for ~92% of peak.
- **Balanced:** `max = 1850` — top of the tested range, still ≤ 60 °C here.
- **Max performance:** `max = 2000` — highest throughput, runs hot (~90 °C+); your call, with
  cooling + monitoring (see [Going to 2000 MHz](#going-to-2000-mhz-the-top-safe-point)).
- Keep `throttling = 85` on at every tier.
- **Undervolt cautiously:** drop a safe-point's `voltage` by 10–20 mV at a time, stress-test
  (the unlock guide's `llama-bench` loop, or furmark/OCCT), and back off on any instability.
- Enable the service so settings persist: `sudo systemctl enable cyan-skillfish-governor-smu`.

*No warranty. Undervolting/overclocking can crash the GPU; keep `throttling` on and a remote
shell handy.*
