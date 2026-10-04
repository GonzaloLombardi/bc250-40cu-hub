# CPU frequency scaling & idle states on Bazzite (ACPI fix) — tested

The BC-250's stock BIOS exposes no CPU P-states or C-states to Linux: there is no `cpufreq`
directory, no CPU governor, and no `cpuidle` driver. The community
[bc250-acpi-fix](https://github.com/bc250-collective/bc250-acpi-fix) adds two SSDT tables
(`SSDT-PST`: 8 P-states, 800–3200 MHz; `SSDT-CST`: C1–C3) through an initramfs override.
This page is the rpm-ostree procedure from the
[community docs](https://elektricm.github.io/amd-bc250-docs/system/governor/#acpi-fix-installation),
**applied and measured on our board** (Oct 2026).

> ← Back to the [hub README](../README.md). This is about the **CPU**. It doesn't touch the 40 CU
> unlock or the GPU governor, and both kept working unchanged with it installed.

> ⚠️ The stock tables cover **12 threads** (`\_PR.P000`–`P00B`), which is right for the stock
> 6c/12t CPU. If you do (or might do) the [8-core unlock](cpu-8core-unlock-bazzite.md), use the
> 16-thread tables from
> [mendesrr/bc250-acpi-fix-updated-8c](https://github.com/mendesrr/bc250-acpi-fix-updated-8c)
> instead. They work on 6 cores too; we run them now
> ([how to switch](cpu-8core-unlock-bazzite.md#acpi-tables-switch-to-the-16-thread-set)).
> Check first with `cat /sys/bus/acpi/devices/LNXCPU:00/path` → it should print `\_PR_.P000`.

---

## Install (rpm-ostree / Bazzite)

```bash
sudo ostree admin pin 0                      # keep the current deployment as a fallback
git clone https://github.com/bc250-collective/bc250-acpi-fix.git
sudo mkdir -p /etc/dracut.conf.d/acpi
sudo cp bc250-acpi-fix/SSDT-CST.aml bc250-acpi-fix/SSDT-PST.aml /etc/dracut.conf.d/acpi/
printf 'acpi_override="yes"\nacpi_table_dir="/etc/dracut.conf.d/acpi"\n' | sudo tee /etc/dracut.conf.d/99-acpi-override.conf
sudo rpm-ostree initramfs --enable
sudo systemctl reboot
```

`rpm-ostree initramfs --enable` regenerates the initramfs on every deployment, so the override
survives image updates (`rpm-ostree status` shows `Initramfs: regenerate`). Image updates get a
bit slower, because the initramfs is built locally.

## Verify

```bash
sudo dmesg | grep -i "SSDT ACPI table found in initrd"   # both SSDT-CST.aml and SSDT-PST.aml
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver  # acpi-cpufreq
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor  # schedutil (Bazzite default)
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies
#   3200000 2550000 2325000 1960000 1820000 1600000 1271000 800000
cat /sys/devices/system/cpu/cpuidle/current_driver       # acpi_idle
grep . /sys/devices/system/cpu/cpu0/cpuidle/state*/name  # POLL C1 C2 C3
```

All of the above matched on our board (Bazzite `44.20260929`, kernel 7.2.7). `schedutil` was
already the default, so nothing else had to be set.

---

## What it changed (measured)

Package power is the SMU's `PPT` (`power1_input` on the amdgpu hwmon). We first checked that it
tracks the CPU: loading all 12 threads raises it by ~34 W. The board has no usable RAPL or
`zenergy` counters.

**Idle and GPU compute: no measurable change.**

| | Before fix | After fix |
|---|---|---|
| Idle: package power / GPU / CPU temp | 42.8 W / 55 °C / 56 °C | 42.5 W / 55 °C / 56 °C |
| Idle: average CPU clock | ~2140 MHz | ~950 MHz (mostly in C2/C3) |
| pp512 (40 CU, GPU-bound) | 1072 tok/s, 137 W, GPU 77 °C | 1071 tok/s, 141 W, GPU 76 °C |

Before the fix the kernel already idled the cores with plain `HLT`, so the real-world idle saving
is negligible. For comparison, forcing the worst case (max clock, C-states disabled) idles at
51.6 W, so the stock BIOS wasn't burning that.

**CPU under full load: still boosts.** With all threads busy the cores run at **~3490 MHz**, above
the 3200 MHz top P-state (firmware boost). There's no CPU performance loss from installing the fix.

**What the fix really gives you: a CPU frequency cap, i.e. a heat knob.** Without `cpufreq` you
can't limit the CPU at all. With it:

| `scaling_max_freq` (12 threads at 100 %) | Package power | CPU temp | Actual clock |
|---|---|---|---|
| 3200 MHz (default, boost active) | 76 W | **91 °C** | 3490 MHz |
| 2550 MHz | 53 W | **65 °C** | 2544 MHz |
| 1960 MHz | 50 W | 60 °C | 1952 MHz |

The boost range is very inefficient: dropping from 3.49 to 2.55 GHz (−27 % clock) saves
**23 W and 25 °C**. Since CPU and GPU share one die and one heatsink, that matters for loads that
use both (games). It doesn't matter for GPU compute like llama.cpp, where the CPU sits near
1 GHz anyway. Note that capping at 3200 MHz does *not* stop the boost; 2550 MHz is the first
step that does.

Try a cap at runtime (resets on reboot):

```bash
echo 2550000 | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq   # cap
echo 3200000 | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq   # back to default
```

To make a cap permanent, use a small systemd oneshot or your power-profile tool. Pick the value
for your workload: it costs single-thread performance in CPU-bound tasks.

---

## Revert

```bash
sudo rpm-ostree initramfs --disable
sudo rm -r /etc/dracut.conf.d/acpi /etc/dracut.conf.d/99-acpi-override.conf
sudo systemctl reboot
```

Or boot the previous (pinned) deployment from the boot menu / `rpm-ostree rollback`. *(Revert
not tested by us; the install side and all measurements above were.)*

---

*Credits: tables by [bc250-collective/bc250-acpi-fix](https://github.com/bc250-collective/bc250-acpi-fix);
rpm-ostree method from [elektricM/amd-bc250-docs](https://github.com/elektricM/amd-bc250-docs).
No warranty: this overrides firmware ACPI tables. Keep a fallback deployment pinned.*
