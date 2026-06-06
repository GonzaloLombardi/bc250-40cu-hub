# bc250-40cu-hub

**A reference hub for unlocking all 40 compute units on the AMD BC-250** (Cyan Skillfish,
`gfx1013`, PCI `1002:13fe`) — salvaged PS5 APUs that ship with only **24 of 40 CUs** active.

This repo does **not** replace the great tools that already exist. It **indexes** them,
explains *which method fits which situation*, and adds the missing piece: a **tested,
end-to-end guide for immutable / atomic distros (Bazzite)** using the runtime-UMR approach.

> **New here?**
> - On **Bazzite / Fedora Atomic** → go straight to the **[Bazzite runtime-UMR guide »](docs/bazzite-40cu-runtime-umr.md)**
> - On a **normal/mutable distro** → use the kernel patch from [duggasco/bc250-40cu-unlock](https://github.com/duggasco/bc250-40cu-unlock)

---

## The hardware in one table

| | Value |
|---|---|
| Device | AMD BC-250 — Cyan Skillfish, `gfx1013` (RDNA2) |
| PCI ID | `1002:13fe` |
| CUs | **40 total**, 24 enabled stock, 16 harvested (firmware policy, no silicon defect) |
| Layout | 4 shader arrays (SE0.SH0/SH1, SE1.SH0/SH1) × 5 WGPs × 2 CUs = 40 |
| Typical gain | ~1.5–1.6× compute throughput (prefill / pp512) |

**Registers involved** (same for every method):

| Register | Stock | Unlocked |
|---|---|---|
| `CC_GC_SHADER_ARRAY_CONFIG` | `0xfff80000` | `0xffe00000` |
| `SPI_PG_ENABLE_STATIC_WGP_MASK` | `0x07` | `0x1f` |
| `RLC_PG_ALWAYS_ON_WGP_MASK` | — | `0x1f` |

---

## Which method should I use?

| Method | Best for | How it works | Survives kernel update | Reverts by |
|---|---|---|---|---|
| **Kernel patch** ([duggasco]) | Mutable distros (build your own kernel) | Patches `amdgpu`, writes regs at driver init; `active_cu_number` becomes 40 | rebuild needed | remove modprobe cfg / restore module |
| **Runtime UMR** ([WinnieLV]) — **recommended for Bazzite** | Immutable / atomic (Bazzite, Fedora Atomic) | Writes regs from userspace post-boot via `umr`; optional systemd persistence | ✅ yes (no kernel touch) | `stock-dispatch` or reboot |
| **Prebuilt RPM override** | Bazzite **only if** the build matches your exact kernel | `rpm-ostree override replace` of a patched-kernel RPM set | ❌ pins your kernel | `rpm-ostree rollback` |

> ⚠️ The prebuilt-RPM route is the common trap: those `.7z` RPM sets are pinned to a
> specific kernel (e.g. `6.17.7-ba29.fc43`). If `uname -r` doesn't match, the override
> **downgrades your kernel**. Prefer runtime-UMR on atomic systems. See the
> [Bazzite guide](docs/bazzite-40cu-runtime-umr.md#why-not-the-normal-kernel-patch-method-on-bazzite).

[duggasco]: https://github.com/duggasco/bc250-40cu-unlock
[WinnieLV]: https://github.com/WinnieLV/bc250-cu-live-manager

---

## Guides in this repo

- 📘 **[Unlocking 40 CUs on Bazzite (runtime-UMR)](docs/bazzite-40cu-runtime-umr.md)** —
  tested end-to-end on Bazzite 44 / kernel 7.0.9-fc44: rollback pin → layer `umr` →
  read harvest map → dry-run → apply → **A/B benchmark (1.55×)** → systemd persistence →
  revert. Includes the kernel-version pitfall and troubleshooting.
- 🎚️ **[Governor & clock/voltage tuning](docs/governor-tuning.md)** — `cyan-skillfish-governor-smu`
  `config.toml` explained, plus a **measured frequency sweep at 40 CU** (1500/1700/1850/2000 MHz →
  throughput, temp, power), the **1700 MHz efficiency sweet spot**, and a cooling-dependency note.
- 🧩 **[Selective WGP/CU masking](docs/selective-wgp-masking.md)** — for **scattered-harvest or
  faulty-WGP boards**: `SE.SH.WGP` addressing, `enable-wgp`/`disable-wgp`, the driver-active
  lock, a bisection workflow to find a bad WGP, and persisting a custom (e.g. 38/40) layout.
- 🛠️ **[Kernel-patch method (mutable distros)](docs/kernel-patch-mutable-distros.md)** — quick
  reference for Arch/CachyOS/Fedora/Debian using [duggasco]'s patch (build script, manual,
  PKGBUILD), with verification and revert. *Not for atomic distros — use runtime-UMR there.*

See also: [`upstream/`](upstream/) — bug report filed upstream as [bc250-cu-live-manager#3](https://github.com/WinnieLV/bc250-cu-live-manager/issues/3).

### Gotchas worth knowing
- **Unstable DRI instance breaks boot persistence.** `write-service-table` bakes the current
  `UMR_INSTANCE` into the boot config, but the DRI number isn't stable across boots (a
  power-cycle flips `card1`↔`card0`), so the service can silently fail back to 24 CU. Blank
  `UMR_INSTANCE` so it auto-detects each boot —
  [details & fix](docs/bazzite-40cu-runtime-umr.md#️-important-blank-umr_instance-so-the-service-survives-every-boot).

---

## Reference index

### Core tools
- **[duggasco/bc250-40cu-unlock](https://github.com/duggasco/bc250-40cu-unlock)** — the
  original register research, kernel patch, build scripts, whitepaper & technical report.
  Submitted upstream as CachyOS/kernel-patches#159 (not yet merged).
- **[WinnieLV/bc250-cu-live-manager](https://github.com/WinnieLV/bc250-cu-live-manager)** —
  runtime-UMR live manager (interactive TUI + CLI + systemd persistence). The tool used by
  the Bazzite guide here. Builds on gennro's live-unlock test.

### Documentation & community
- **[elektricM/amd-bc250-docs](https://github.com/elektricM/amd-bc250-docs)**
  ([site](https://elektricm.github.io/amd-bc250-docs/)) — the community documentation hub:
  distro guides, kernel notes, 40CU unlock section, governor setup.

### Governor / thermal & clocks
- **[filippor/cyan-skillfish-governor](https://github.com/filippor/cyan-skillfish-governor)**
  (SMU branch) — userspace GPU governor to cap/tune frequency & voltage (e.g. 1500 MHz /
  900 mV) and manage thermals.

### Benchmark
- **[ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp)** — prebuilt Vulkan binaries
  (`llama-bench -p 512`) make a clean A/B compute test for verifying the CU scaling.

> Have a reference that belongs here (a video, a board harvest-map survey, a patched image)?
> Open a PR or an issue.

---

## Status & roadmap

- [x] Bazzite runtime-UMR guide (tested, with benchmark)
- [x] Selective WGP masking guide for scattered-harvest boards
- [x] Governor tuning notes (safe-point profiles, thermal data)
- [x] Mutable-distro (kernel patch) quickstart cross-link
- [x] Report upstream: `write-service-table` bakes a volatile `UMR_INSTANCE` — filed as
      [WinnieLV/bc250-cu-live-manager#3](https://github.com/WinnieLV/bc250-cu-live-manager/issues/3)
      (follow-up to their #1)
- [ ] Optional: offer a PR to WinnieLV for the fix (blank `UMR_INSTANCE` / re-detect at boot)
- [x] Polish: add a LICENSE (CC BY 4.0)
- [ ] Decide on upstream contributions (PRs to elektricM docs / WinnieLV README)
- [ ] Optional: screenshots / asciinema of `status` + benchmark

---

## Credits & license

The original documentation in this repo is licensed under
**[CC BY 4.0](LICENSE)** — reuse and adapt freely **with attribution** (e.g. *"based on
bc250-40cu-hub by GonzaloLombardi, CC BY 4.0"* + a link back).

All upstream work belongs to its respective authors (linked above) under their own
licenses. This repo is an independent index + original documentation; it redistributes
**no** third-party code — it links to it.

*No warranty. The unlock writes low-level GPU registers and raises power/thermals — keep a
remote shell and adequate cooling, and read each tool's own safety notes first.*
