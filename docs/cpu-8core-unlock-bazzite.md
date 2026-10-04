# 8-core CPU unlock on Bazzite (runtime, no BIOS flash) — tested

The BC-250 ships with 6 of its 8 Zen 2 cores active. The other two aren't fused off. They're
masked by an SMU register (`SMN 0x0115A870`: `0x77` → `0xFF`), one core per CCX. The full
background is on the [community page](https://elektricm.github.io/amd-bc250-docs/system/8core-unlock/).
This page is **what we did and measured on our board** (Oct 2026), using the same live-manager
script as the [40 CU guide](bazzite-40cu-runtime-umr.md).

> ← Back to the [hub README](../README.md). Combine with the
> [CPU ACPI fix](cpu-acpi-fix-bazzite.md). With 8 cores you need its **16-thread** tables
> (see below), or the two new cores get no frequency scaling and no idle states.

---

## How it behaves (read first)

- **Warm reboot keeps it, cold boot loses it.** `systemctl reboot` keeps the unlock. Power-off,
  PSU switch or unplug reverts the mask to `0x77`, so you're back on 6 cores. Nothing is
  written to flash, so cutting power is a guaranteed way back to stock.
- **It needs a reboot to show up.** The mask is written live, but firmware only enumerates the
  extra cores on the next (warm) boot.
- **The GPU governor has to be stopped during the SMU access.** Both use the same index/data
  pair on `00:00.0`. The live-manager script does this for you (it stops and restarts
  `cyan-skillfish-governor-smu`).
- **Don't automate the reboot.** The community documented a bootloop with an older tool that
  rebooted on its own. The live-manager script never reboots with `--yes`; it only tells you to.

## Steps

```bash
# 1) Read the mask without writing (stops/restarts the GPU governor around the read)
sudo ~/bc250-cu-live-manager.sh cpu-unlock --dry-run
#   [ OK ] core presence mask: 0x00000077          <- the script aborts on any other value

# 2) Write it
sudo ~/bc250-cu-live-manager.sh cpu-unlock --yes
#   [ OK ] core mask after write: 0x000000ff
#   [ OK ] reboot when ready to bring up all 8 cores (16 threads)

# 3) Warm reboot (NOT power-off)
sudo systemctl reboot

# 4) Verify
lscpu | grep -E '^CPU\(s\)|Core\(s\) per socket'      # 16 / 8
sudo ~/bc250-cu-live-manager.sh status | grep 'CPU '  # 16 threads present, 16 online; unlocked 8c/16t
```

Some boards don't read `0x77` (`0xB7` and `0xD7` have been reported). The script refuses to
write an unexpected mask. Ours was the standard `0x77`.

## ACPI tables: switch to the 16-thread set

With the 6-core [ACPI fix](cpu-acpi-fix-bazzite.md) installed, the new cores (CPUs 12–15 = cores
6 and 7 on our board) came up with **no `cpufreq` and no `cpuidle`**, so you can't cap them and
they can't sleep. [mendesrr/bc250-acpi-fix-updated-8c](https://github.com/mendesrr/bc250-acpi-fix-updated-8c)
extends both tables to `\_PR.P00F` (same P-state table). It works **on both 6 and 8 cores**,
which matters because a cold boot drops you back to 6.

On the rpm-ostree setup from the ACPI page, overwrite the two files and rebuild the initramfs.
There's no "regenerate" flag, so disable and re-enable:

```bash
git clone https://github.com/mendesrr/bc250-acpi-fix-updated-8c.git
sudo cp bc250-acpi-fix-updated-8c/SSDT-CST.aml bc250-acpi-fix-updated-8c/SSDT-PST.aml /etc/dracut.conf.d/acpi/
sudo rpm-ostree initramfs --disable && sudo rpm-ostree initramfs --enable
sudo systemctl reboot        # warm reboot, keeps the 8 cores
```

Verified after the reboot: both SSDTs load from the initrd, and all 16 CPUs report `schedutil`
and 4 idle states.

---

## Results (measured)

**Correctness first:** `stress-ng --cpu-method all --verify` passed 60 s on the new cores alone
(`taskset -c 12-15`, 4/4) and on all 16 threads (16/16). No machine-check errors in the kernel
log.

**7-Zip (`7z b`, same benchmark as the community page):**

| Config | Multi-thread | 1 thread | Package power | CPU peak |
|---|---|---|---|---|
| 6 cores, boost | 40,185 MIPS | 3,883 | 64 W | 77 °C |
| **8 cores, boost** | **52,614 MIPS (+31 %)** | 3,918 | 73 W | 81 °C |
| 6 cores, cap 2550 MHz | 30,640 | 3,088 | 49 W | 62 °C |
| **8 cores, cap 2550 MHz** | **36,263** | 3,071 | 52 W | 62 °C |
| 8 cores, cap 1960 MHz | 31,267 | 2,527 | 49 W | 58 °C |

- +31 % multi-thread at stock clocks; single-thread unchanged.
- **8 cores capped at 2550 MHz ≈ 90 % of 6 cores with boost, for 12 W and 15 °C less.**
  8 cores at 1960 MHz beat 6 cores at 2550 MHz.
- Idle cost: none (42.1 W vs 42.5 W at 6 cores, with the 16-thread tables).

**CPU + GPU together** (`stress-ng` on all 16 threads + llama.cpp pp512 on the 40 CU GPU, the
closest thing to a heavy game):

| CPU setting | GPU pp512 | Package power | CPU avg / peak | GPU avg / peak |
|---|---|---|---|---|
| boost | 1042 tok/s | 127 W | 89 / **94 °C** | 73 / 83 °C |
| cap 2550 MHz | **1048 tok/s** | 117 W | 71 / 79 °C | 72 / 82 °C |

On our board (weak airflow, external fan), boosting all 8 cores under a combined load runs the
CPU within a degree of 95 °C. Capping at 2550 MHz drops it 15 °C and the GPU is, if anything,
slightly faster, because the CPU stops eating into the shared power budget.

## Side effects

- **GPU frequency readouts break**, as the community page warns: `pp_dpm_sclk` shows `16Mhz`, the
  amdgpu hwmon `freq1_input` reads ~14 MHz, and `gpu_busy_percent` is empty. **It's monitoring
  only.** GPU throughput is unchanged (pp512 1071 tok/s at 8 cores) and the governor keeps
  working. Our [`sweep-clocks.sh`](../scripts/sweep-clocks.sh) sclk column is meaningless while
  8 cores are up. The governor has a `fix-freq` option aimed at this; we didn't need it.
- **The 40 CU unlock is unaffected**: 40/40, validate PASS.
- **Re-validate any CPU or GPU undervolt.** The community notes that 8 cores sag the shared rail
  more. We run stock voltages (see [why](governor-tuning.md#undervolting-test-for-wrong-answers-not-just-crashes)).

## Revert

Power the board off completely (not reboot) and you're back on 6 cores. The 16-thread ACPI
tables can stay; they're correct for 6 cores too.
