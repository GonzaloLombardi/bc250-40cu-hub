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
# Bazzite / Fedora Atomic (rpm-ostree): layer it, then reboot
sudo rpm-ostree install cyan-skillfish-governor-smu
systemctl reboot

# Fedora (mutable): from the COPR
sudo dnf copr enable filippor/bazzite
sudo dnf install cyan-skillfish-governor-smu

# Arch: AUR package          →  paru -S cyan-skillfish-governor-smu
# Debian / others: a .deb or release tarball from GitHub Releases (see upstream README)

sudo systemctl enable --now cyan-skillfish-governor-smu.service
systemctl is-active cyan-skillfish-governor-smu
```

Config: **`/etc/cyan-skillfish-governor-smu/config.toml`** (world-readable). Apply changes
with `sudo systemctl restart cyan-skillfish-governor-smu`.

> The RPM marks the config `%config(noreplace)`. That means: **if you never edited it**, an
> upgrade replaces it with the new default (that's what happened on our board going to
> v0.4.14; the file gained `temp-read`). **If you did edit it**, your file is kept and the new
> default lands next to it as `config.toml.rpmnew`, so newer keys just take built-in defaults
> until you merge them. Compare against upstream's
> [`default-config.toml`](https://github.com/filippor/cyan-skillfish-governor/blob/smu/default-config.toml).
>
> Check what you actually run with `rpm -q cyan-skillfish-governor-smu`: the `g<hash>` suffix is
> the source commit. Our June install said `v0.4.6` but was built from `g7f91021`, a December 2025
> commit. Notes below were checked against **v0.4.14** (Oct 2026), and the sweep was
> re-measured on it.

---

## Understanding `config.toml`

```toml
[gpu]
set-method = "smu"     # "smu" (drive the SMU directly) or "kernel"

[gpu-usage]
method = "busy-flag"   # "busy-flag", "process", or "kernel" (needs a patched kernel)
temp-read = "drm"      # "drm" or "sysfs": where the GPU temperature is read (v0.4.13+)
fix-freq = false       # work around unreliable sysfs freq readings (e.g. after 8-core unlock)

[dbus]
enabled = true         # runtime control via busctl / cyan-skillfish-performance-mode

[frequency-range]
min = 1000    # MHz — floor
max = 1850    # MHz — ceiling (omit the key for no limit; do NOT set 0, see below)

[load-target]
upper = 0.65  # ramp up above 65% busy
lower = 0.50  # ramp down below 50% busy

[temperature]
throttling = 85           # °C — hard safety: clock down when hit
throttling_recovery = 75  # °C — resume when back under

# Frequency → voltage curve. Voltage is interpolated linearly between points.
[[safe-points]]
frequency = 1500
voltage = 900
[[safe-points]]
frequency = 1700
voltage = 920
[[safe-points]]
frequency = 1850
voltage = 930
# ... up to 2000 / 960 (plus commented-out points up to 2400 / 1150 in the shipped file)
```

Key ideas:
- **`safe-points`** define the voltage curve and its span. Since v0.4.11
  ([`606f5ce`](https://github.com/filippor/cyan-skillfish-governor/commit/606f5ce)) the governor
  **interpolates linearly** between neighbouring points, so a frequency between 1700 and
  1850 MHz gets a voltage between 920 and 930 mV. Older versions only used the listed pairs.
  Lowering a point's `voltage` undervolts that whole segment of the curve: cooler and less
  power, but unstable if you go too far. Frequencies outside the first and last point are
  rejected.
- **`frequency-range.max`** is your real ceiling. Raising it lets the governor climb further
  up the curve under load. The range is clamped to the span of the safe-points. **Don't set
  `max = 0`** expecting "no limit" (the shipped file's own comment still says you can): it gets
  clamped up to the lowest safe point and pins the GPU there. Tested on v0.4.14: the log shows an
  inverted `initial frequency range: 1000..=500`, the clock stays at **500 MHz even under load**,
  and pp512 drops from 1072 to **305 tok/s**. Omit the key instead.
- **`temperature.throttling`** is the governor's safety net. Leave it on (85 °C is sane) even
  while experimenting. Until the governor *service* is enabled, any crash reboots to stock clocks.
- **There's a second, lower limit:** with `set-method = "smu"` the governor also sets the SMU's
  own GPU temperature limit to **80 °C** at startup (`set_gpu_max_temperature(80)` in
  `src/gpu.rs`, added Feb 2026; builds from older sources, like our June `g7f91021` one, don't
  set it). **Don't count on it as a cap:** in our October sweep on v0.4.14 the edge sensor went
  to 91 °C, and the clock only dipped slightly (avg 1981 MHz at a 2000 MHz pin). That's consistent
  with the governor's own 85 °C throttle, with no sign of a hard 80 °C firmware limit. What the
  SMU does with that value isn't documented. If you also run
  [bc250_smu_oc](https://github.com/bc250-collective/bc250_smu_oc), note that it writes its own
  SMU temperature limit (90 °C by default), and whichever tool runs last wins.

---

## Measured sweep (40 CU, Bazzite 44)

**October 2026 run** (Bazzite `44.20260929`, kernel 7.2.7, Mesa 26.2.2, governor **v0.4.14**,
default curve). Each frequency was pinned with `cyan-skillfish-performance-mode
--fixed-frequency F`, then `llama-bench -p 512 -r 10` (Qwen2.5-3B Q4_K_M, llama.cpp `b9538`)
ran at 40 CU. Sensors were sampled every 0.5 s **during** the load: averages are over the
loaded samples, and peaks are the max. Between points the board cooled in adaptive mode.
Reproduce it on your board with [`scripts/sweep-clocks.sh`](../scripts/sweep-clocks.sh) (no root
needed).

| Freq | pp512 (tok/s) | Avg sclk | Avg vddgfx | Temp avg / peak | PPT avg / peak | tok/s per W |
|---|---|---|---|---|---|---|
| 1500 MHz | 881 | 1500 | 874 mV | 78 / 80 °C | 115 / 122 W | 7.65 |
| 1700 MHz | 992 | 1700 | 887 mV | 83 / 84 °C | 128 / 142 W | **7.74** |
| 1850 MHz | 1068 | 1842 | 897 mV | 85 / 86 °C | 142 / 147 W | 7.54 |
| 2000 MHz | 1140 | 1981 | 919 mV | 89 / **91 °C** | 158 / 168 W | 7.21 |

How to read it:
- **Throughput matches June within 1 %** at every point (873/983/1062/1144 then). Four
  months of kernel, Mesa and governor updates changed nothing on the compute side.
- **PPT is package power (CPU + GPU)**, so it isn't only the GPU. On this board the CPU has no
  frequency-scaling driver loaded (stock BIOS; see the community notes on the ACPI fix), which
  keeps the package idling around 47 W.
- **`vddgfx` reads below the safe-point voltages** (e.g. 919 mV at 2000 MHz vs a 960 mV
  point). The SMU applies its own offset under load. Judge undervolts by stability, not by
  this readout.
- **The temperatures are the outlier, and that's cooling.** At 2000 MHz the June run peaked
  at 161 W and 73 °C. This one peaked at 168 W and **91 °C**: almost the same power, +18 °C.
  Same board, same clocks, but with an idle GPU at 63 °C, motherboard "System" sensor at 57 °C
  and VRM at 57 °C *before* any load, which points at case airflow (and a warmer season). At
  1850 and 2000 MHz the governor's 85 °C throttle trims the clock slightly (avg sclk 1842 /
  1981). Here is the ❄️ note below, demonstrated on one board.

<details>
<summary>June 2026 run (governor built from <code>g7f91021</code>, mixed methodology)</summary>

| Freq cap | pp512 (tok/s) | Voltage | Temp | Power | Notes |
|---|---|---|---|---|---|
| 1500 MHz | 873 | 837 mV | 53 °C | 53 W | post-run steady |
| 1700 MHz | 983 | 912 mV | 57 °C | 64 W | post-run steady |
| 1850 MHz | 1062 | 918 mV | 60 °C | 80 W | post-run steady |
| 2000 MHz | 1144 | 960 mV | 73 °C peak | ~161 W peak | live peak sampling, no throttle |

The 1500–1850 rows were read *after* each run, so their power/temp undershoot the load values.
Only the 2000 MHz row was sampled live. Don't compare those rows with the October table.
</details>

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
- Throughput scales **almost linearly** with frequency (1500 → 2000 MHz: +33 % clock →
  +29 % tok/s).
- **Power scales a bit faster than performance.** Each step up buys ~7–13 % throughput for
  ~10–12 % more package power. **1700 MHz has the best tok/s per watt**, but the spread is
  small (7.2–7.7). Pick by temperature as much as by efficiency.
- **Temperature is what decides the ceiling, and it depends on your cooling.** With good
  airflow (June) the whole range stayed ≤ 73 °C. With poor airflow (October) 1850 already sits
  at the 85 °C throttle and 2000 MHz overshoots to 91 °C. The 40 CU unlock adds load, so
  check yours.

> Note: combine this with the unlock — at a *fixed* clock, going 24 → 40 CU is the larger
> win (≈1.55× from the [unlock benchmark](bazzite-40cu-runtime-umr.md#step-5--verify-it-does-real-work-benchmark));
> clock tuning is the second-order knob on top.

---

## How to pin a frequency for benchmarking

The governor is load-adaptive, so to measure a single clock cleanly you need to hold it fixed.

**Easiest (current versions, D-Bus enabled):** use the performance-mode helper. Thermal
throttling stays active, and no config edit or restart is needed:

```bash
cyan-skillfish-performance-mode --fixed-frequency 1700   # pin
cyan-skillfish-performance-mode --status
cyan-skillfish-performance-mode --off                    # back to adaptive
```

The raw equivalents (tested) are
`busctl --system call com.cyanskillfish.Governor /com/cyanskillfish/Governor com.cyanskillfish.Governor.PerformanceMode SetFixedFrequency u 1700`
and, to turn it off,
`busctl --system set-property com.cyanskillfish.Governor /com/cyanskillfish/Governor com.cyanskillfish.Governor.PerformanceMode Enabled b false`.

> ⚠️ **Wrapper mode doesn't clean up (v0.4.14).** Upstream documents
> `cyan-skillfish-performance-mode --fixed-frequency 1700 -- some-command` as "enable, run,
> disable on exit", but the script sets `trap cleanup EXIT` and then `exec`s the command, and
> `exec` replaces the shell, so the trap never runs. On our board the clock **stayed pinned**
> after the wrapped command exited, with or without `--`, whether it succeeded or failed. If
> you use the wrapper (e.g. as a Steam launch option), run `--off` afterwards, or a pinned
> clock will keep the GPU hot at idle.

**Config-file method** (how the June sweep was measured; works on any version): set
`min = max`:

```bash
sudo sed -i 's/^\s*min = .*/min = 1700/; s/^\s*max = .*/max = 1700/' \
  /etc/cyan-skillfish-governor-smu/config.toml
sudo systemctl restart cyan-skillfish-governor-smu
cat /sys/class/hwmon/hwmon*/freq1_input   # confirm it's holding (Hz)
```

Restore your range (e.g. `min = 1000`, `max = 1850`) and restart when done. Note that sysfs
frequency readings on this board can be unreliable (see `fix-freq` above). Watch live:

```bash
HW=$(for h in /sys/class/hwmon/hwmon*; do grep -qi amdgpu "$h/name" && echo "$h"; done)
watch -n1 'echo "$(($(cat '"$HW"'/temp1_input)/1000))C $(($(cat '"$HW"'/power1_average)/1000000))W $(($(cat '"$HW"'/freq1_input)/1000000))MHz"'
```

---

## Going to 2000 MHz (the top safe-point)

The default config already ships a `2000 MHz / 960 mV` safe-point — the unlock doesn't cap
your clocks, so **whether to use it is entirely your decision**. It's the highest-throughput
setting (**~1140 tok/s here, ~1.07× over 1850 MHz**), at the cost of meaningfully more heat and
power (package peak ~165 W). Our own board shows both sides. In June, with good airflow, it held
a flat 2000 MHz at **73 °C peak**. In October, with poor airflow, it hit **91 °C** and the
governor had to throttle it a little. Community boards with weak cooling report ~90–96 °C too.
Same registers, wildly different temps: it's a "know your cooling + monitor" setting, not
fire-and-forget.

To raise the ceiling so the governor can reach 2000 MHz under load:

```bash
sudo sed -i 's/^\s*max = .*/max = 2000/' /etc/cyan-skillfish-governor-smu/config.toml
sudo systemctl restart cyan-skillfish-governor-smu
```

Then **stress-test while watching temps live** (use the `watch` one-liner above, or the
`llama-bench` loop from the unlock guide). The `throttling = 85` line is your safety net: it
clocks down before things get dangerous. It reacts, so expect a few degrees of overshoot
(91 °C peak in our hot run). Recommended checks before keeping it:

- Temp stays below your comfort threshold under sustained load (the 85 °C throttle is a
  ceiling, not a target — many prefer to keep peaks in the low 80s).
- No GPU resets/crashes in `dmesg` during a stress run.
- If unstable, either drop `max` back to 1850, or nudge the 2000 MHz safe-point's `voltage`
  up a touch (e.g. 960 → 970 mV) for more headroom. With interpolation, that also raises the
  voltage for everything between 1850 and 2000 MHz.
- The shipped config has commented-out points above 2000 MHz (up to 2400 MHz / 1150 mV). Those
  go beyond what this doc measured. Don't uncomment them without serious cooling, and never
  exceed what upstream lists.

Revert anytime: set `max` back to `1850` (or `1700`) and restart the service.

## Undervolting: test for wrong answers, not just crashes

The usual advice is "lower the voltage until it crashes, then back off". On our board that would
have been dangerous: **the first failure was silent.** At 1850 MHz, 890 mV benchmarked at full
speed with a clean `dmesg`, but a deterministic llama.cpp generation (temp 0, fixed seed)
produced **different text** than at stock voltage. The GPU was computing wrong results without
any sign of trouble.

Measured with [`scripts/undervolt-test.sh`](../scripts/undervolt-test.sh) (governor TestMode,
no config edits; Oct 2026, governor v0.4.14):

| 1850 MHz @ | pp512 (tok/s) | Avg vddgfx | Package power | Same output as stock? |
|---|---|---|---|---|
| 930 mV (shipped) | 1072 | 900 mV | 130–136 W | ✅ reference |
| 910 mV | 1071 | 881–887 mV | 133–137 W | ✅ 3 of 3 runs |
| 890 mV | 1071 | 856–858 mV | 115–133 W | ❌ **2 of 2 runs mismatched** (no crash, no dmesg errors) |

Takeaways for this board:
- **The shipped curve has very little margin:** just 20 mV between the default and silent
  miscompute.
- **The one safe step (−20 mV) saved nothing measurable** in package power or temperature, so
  it isn't worth the risk. We left the shipped voltages alone.
- If you undervolt yours, check correctness and not only stability: compare a deterministic
  output, or use the script above, which stops at the first mismatch. Keep at least one passing
  step of margin below the value you settle on.

## Recommended starting point

- **Efficiency:** `max = 1700` (best tok/s per watt) — ~87 % of peak throughput. On a board
  with poor airflow it's also the highest point that stays clear of the 85 °C throttle (83 °C
  avg in our hot run).
- **Balanced:** `max = 1850` (the shipped default) — ~94 % of peak. Fine with decent cooling
  (≤ 60 °C in June); it sits right at the throttle threshold when airflow is poor.
- **Max performance:** `max = 2000` — highest throughput, runs hot (~90 °C on weak cooling);
  your call, with cooling + monitoring (see [Going to 2000 MHz](#going-to-2000-mhz-the-top-safe-point)).
- If your board idles hot (GPU edge above ~60 °C, motherboard "System" sensor above ~50 °C),
  **fix the airflow before tuning clocks**. It's worth more than any safe-point tweak.
- Keep `throttling = 85` on at every tier.
- **Undervolt cautiously, if at all:** drop a safe-point's `voltage` by 10–20 mV at a time, and
  test for **wrong output**, not just crashes (see [above](#undervolting-test-for-wrong-answers-not-just-crashes)).
  On our board it gave no measurable benefit before outputs went wrong.
- Enable the service so settings persist: `sudo systemctl enable cyan-skillfish-governor-smu`.

*No warranty. Undervolting/overclocking can crash the GPU; keep `throttling` on and a remote
shell handy.*
