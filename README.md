# bc250-40cu-hub

**A reference hub for unlocking all 40 compute units on the AMD BC-250** (Cyan Skillfish,
`gfx1013`, PCI `1002:13fe`) — salvaged PS5 APUs that ship with only **24 of 40 CUs** active.

This repo does **not** replace the great tools that already exist. It **indexes** them,
explains *which method fits which situation*, and adds the missing piece: a **tested,
end-to-end guide for immutable / atomic distros (Bazzite)** using the runtime-UMR approach.

> **New here?**
> - On **Bazzite / Fedora Atomic** → go straight to the **[Bazzite runtime-UMR guide »](docs/bazzite-40cu-runtime-umr.md)**
> - On a **normal/mutable distro** → either the [kernel patch](docs/kernel-patch-mutable-distros.md)
>   from duggasco (repo **archived** Sept 2026, still usable) or the same runtime-UMR tool, which
>   now supports apt / pacman / dnf too

---

## The hardware in one table

| | Value |
|---|---|
| Device | AMD BC-250 — Cyan Skillfish, `gfx1013` (RDNA2) |
| PCI ID | `1002:13fe` |
| CUs | **40 total**, 24 enabled stock, 16 harvested (usually healthy, but not guaranteed: test yours) |
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
| **Runtime UMR** ([WinnieLV]) — **recommended for Bazzite** | Any distro; the only no-rebuild option on immutable ones (Bazzite, Fedora Atomic, SteamOS*) | Writes regs from userspace post-boot via `umr`; optional systemd persistence | ✅ yes (no kernel touch) | `stock-dispatch` or reboot |
| **Kernel patch** ([duggasco], ⚠️ archived) | Mutable distros (build your own kernel) | Patches `amdgpu`, writes regs at driver init; `active_cu_number` becomes 40 | rebuild needed | remove modprobe cfg / restore module |
| **Prebuilt Bazzite image** ([62fixolab], `-40cu` variants, experimental) | Bazzite users happy to rebase to a community image | `rpm-ostree rebase` to an image that tracks Bazzite `stable` and bundles the live manager | ✅ follows image updates | `rpm-ostree rebase` back / rollback |
| **Prebuilt RPM override** — avoid | Bazzite **only if** the build matches your exact kernel | `rpm-ostree override replace` of a patched-kernel RPM set | ❌ pins your kernel | `rpm-ostree rollback` |

\* SteamOS persistence is still a pending upstream PR
([bc250-cu-live-manager#7](https://github.com/WinnieLV/bc250-cu-live-manager/pull/7)).

> ⚠️ The prebuilt-RPM route is the common trap: those `.7z` RPM sets are pinned to a
> specific kernel (e.g. `6.17.7-ba29.fc43`). If `uname -r` doesn't match, the override
> **downgrades your kernel**. On atomic systems, prefer runtime-UMR (or a prebuilt image that
> tracks Bazzite). See the
> [Bazzite guide](docs/bazzite-40cu-runtime-umr.md#why-not-the-normal-kernel-patch-method-on-bazzite).

[duggasco]: https://github.com/duggasco/bc250-40cu-unlock
[WinnieLV]: https://github.com/WinnieLV/bc250-cu-live-manager
[62fixolab]: https://github.com/62fixolab/Latest-Bazzite-AMD-BC-250-Patched-Images

---

## Guides in this repo

- 📘 **[Unlocking 40 CUs on Bazzite (runtime-UMR)](docs/bazzite-40cu-runtime-umr.md)** —
  tested end-to-end on Bazzite 44 (kernel 7.0.9 in June 2026, **re-tested on kernel 7.2.7 /
  Mesa 26.2.2 in Oct 2026**): rollback pin → layer `umr` → read harvest map → dry-run →
  apply → **A/B benchmark (1.55–1.56×)** → systemd persistence → revert. Includes the
  kernel-version pitfall and troubleshooting.
- 🎚️ **[Governor & clock/voltage tuning](docs/governor-tuning.md)** — `cyan-skillfish-governor-smu`
  `config.toml` explained, plus a **measured frequency sweep at 40 CU on v0.4.14**
  (1500/1700/1850/2000 MHz → throughput, voltage, temp, package power, tok/s per W), the
  **1700 MHz efficiency sweet spot**, voltage-curve interpolation, D-Bus frequency pinning, and
  a real before/after showing how much airflow changes temps (73 °C vs 91 °C at the same clock).
- 🧩 **[Selective WGP/CU masking](docs/selective-wgp-masking.md)** — for **scattered-harvest or
  faulty-WGP boards**: `SE.SH.WGP` addressing, `enable-wgp`/`disable-wgp`, masking stock WGPs
  live (tested), **what masking costs** (the slowest shader array sets the pace: 38 CU ≈ 90 %,
  36 CU ≈ 32 CU), a bisection workflow to find a bad WGP, and persisting a custom layout.
- 🛠️ **[Kernel-patch method (mutable distros)](docs/kernel-patch-mutable-distros.md)** — quick
  reference for Arch/CachyOS/Fedora/Debian using [duggasco]'s patch (build script, manual,
  PKGBUILD), with verification and revert. *Upstream archived; not for atomic distros.*

Validate a board quickly:
- [`scripts/validate-40cu.sh`](scripts/validate-40cu.sh) — checks the SPI/CC registers on all
  4 shader arrays (PASS/FAIL); `--bench` adds a pp512 run. `sudo ./validate-40cu.sh [--bench]`.
- [`scripts/benchmark-40cu.sh`](scripts/benchmark-40cu.sh) — **A/B proof**: measures pp512 at
  40 CU vs 24 CU and reports the speedup (~1.55× = PASS). Restores 40 CU on exit.
  `sudo ./benchmark-40cu.sh`.
- [`scripts/sweep-clocks.sh`](scripts/sweep-clocks.sh) — **clock sweep**: pins 1500–2000 MHz via
  the governor's D-Bus helper and logs pp512, sclk, vddgfx, temp and power *under load*. This is
  the method behind the governor table. `./sweep-clocks.sh` (no root needed).

See also: [`upstream/`](upstream/) — bug report filed upstream as [bc250-cu-live-manager#3](https://github.com/WinnieLV/bc250-cu-live-manager/issues/3).

### Gotchas worth knowing
- **Live-manager installs from before June 2026: update them.** Two things changed upstream:
  - The boot service could fall back to 24 CU when the DRI instance flipped between boots
    (`card1` ↔ `card0`). We reported it as [#3](https://github.com/WinnieLV/bc250-cu-live-manager/issues/3),
    and it's fixed in [`ce4e373`](https://github.com/WinnieLV/bc250-cu-live-manager/commit/ce4e373).
    [Details](docs/bazzite-40cu-runtime-umr.md#older-builds-stale-umr_instance-breaks-boot-persistence).
  - [`046e36b`](https://github.com/WinnieLV/bc250-cu-live-manager/commit/046e36b) **removed
    `enable-cu`/`disable-cu`** (use the `-wgp` commands), allowed live-disabling stock WGPs, and
    changed the `status` summary to `CUs active & routed : N/40`.
- **Two upstream bugs found while re-testing (Oct 2026), both harmless once you know:**
  `install-umr` errors out on Bazzite when `umr` is already layered (it only checks dpkg and
  pacman; [details](docs/bazzite-40cu-runtime-umr.md#step-1--install-umr-one-reboot)), and the
  governor's `cyan-skillfish-performance-mode … -- command` wrapper **doesn't unpin the clock**
  when the command exits (`exec` skips its cleanup trap;
  [details](docs/governor-tuning.md#how-to-pin-a-frequency-for-benchmarking)). Run `--off`
  afterwards.
- **`active_cu_number` stays 24 with runtime-UMR.** That's expected: it's the driver's boot
  enumeration. The proof that the extra CUs work is the register check plus a compute benchmark
  (see the scripts above). This comes up a lot, e.g.
  [bc250-cu-live-manager#9](https://github.com/WinnieLV/bc250-cu-live-manager/issues/9).

---

## Reference index

### Core tools
- **[WinnieLV/bc250-cu-live-manager](https://github.com/WinnieLV/bc250-cu-live-manager)** —
  runtime-UMR live manager (interactive TUI + CLI + systemd persistence). The tool used by
  the Bazzite guide here. Builds on gennro's live-unlock test. Since June 2026 it also has
  `install-umr` (apt/pacman/paru/rpm-ostree/dnf), Debian support, auto-sudo, and `cpu-unlock`
  (see below).
- **[duggasco/bc250-40cu-unlock](https://github.com/duggasco/bc250-40cu-unlock)** — the
  original register research, kernel patch, build scripts, `cu_map.sh`, health test,
  whitepaper & technical report. **Archived on 17 September 2026** (read-only; still clones).
  Its upstream submission [CachyOS/kernel-patches#159](https://github.com/CachyOS/kernel-patches/pull/159)
  is still open and unmerged, with no activity since May 2026.
- **[62fixolab/Latest-Bazzite-AMD-BC-250-Patched-Images](https://github.com/62fixolab/Latest-Bazzite-AMD-BC-250-Patched-Images)** —
  Bazzite Deck/GNOME/KDE images for the BC-250 (SMU governor, telemetry fix, signed rebases),
  plus experimental `-40cu` variants bundling the live manager via `ujust bc250-cu-*`. Not
  tested by us.

### Documentation & community
- **[elektricM/amd-bc250-docs](https://github.com/elektricM/amd-bc250-docs)**
  ([site](https://elektricm.github.io/amd-bc250-docs/)) — the community documentation hub:
  distro guides, kernel notes, the [40 CU unlock page](https://elektricm.github.io/amd-bc250-docs/system/40cu-unlock/)
  (now with a runtime-UMR option and an rpm-ostree/Bazzite section), and governor setup.
- **[akandr/bc250](https://github.com/akandr/bc250)** — deep dive on LLM inference on this board
  (Ollama + Vulkan, model benchmarks, GTT/TTM memory tuning). Useful once the unlock is done
  and your workload is AI.

### Governor / thermal & clocks
- **[filippor/cyan-skillfish-governor](https://github.com/filippor/cyan-skillfish-governor)**
  (SMU branch, v0.4.14 as of Oct 2026) — userspace GPU governor to cap/tune frequency & voltage
  and manage thermals. Packaged for COPR (Fedora/Bazzite), AUR and `.deb`. Newer versions add
  linear voltage interpolation, a D-Bus API plus the `cyan-skillfish-performance-mode` helper, and
  `temp-read`/`fix-freq` options. See our [tuning guide](docs/governor-tuning.md).

### CPU cores (related)
Not part of the CU unlock, but the same boards, the same tools, and the same thermal budget:
- **8-core unlock**: WinnieLV's script now has `cpu-unlock` (SMU core mask `0x77` → `0xFF`,
  6c/12t → 8c/16t). It takes effect on the next reboot, has to be re-run after a cold power
  cycle, and the extra cores may be unstable. Some boards report a different stock mask
  ([#10](https://github.com/WinnieLV/bc250-cu-live-manager/issues/10)). The community
  [8-core page](https://elektricm.github.io/amd-bc250-docs/system/8core-unlock/) covers the
  firmware route and the ACPI tables.
- **[bc250-collective/bc250_smu_oc](https://github.com/bc250-collective/bc250_smu_oc)** — CPU
  overclock/undervolt via the SMU. **Stop the GPU governor while tuning** (they share the SMU),
  and read its voltage warnings first: the author reports bricking a board. See the
  [community notes](https://elektricm.github.io/amd-bc250-docs/bios/overclocking/).

### Benchmark
- **[ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp)** — prebuilt Vulkan binaries
  (`llama-bench -p 512`) make a clean A/B compute test for verifying the CU scaling. Note that
  builds are now tagged `bNNNN` and marked *pre-release*, so `releases/latest` no longer points
  at them. The [unlock guide](docs/bazzite-40cu-runtime-umr.md#step-5--verify-it-does-real-work-benchmark)
  has a working download snippet.

> Have a reference that belongs here (a video, a board harvest-map survey, a patched image)?
> Open a PR or an issue.

---

## Status & roadmap

- [x] Bazzite runtime-UMR guide (tested, with benchmark)
- [x] Selective WGP masking guide for scattered-harvest boards
- [x] Governor tuning notes (safe-point profiles, thermal data)
- [x] Mutable-distro (kernel patch) quickstart cross-link
- [x] Report upstream: `write-service-table` baked a volatile `UMR_INSTANCE` — filed as
      [WinnieLV/bc250-cu-live-manager#3](https://github.com/WinnieLV/bc250-cu-live-manager/issues/3)
      (follow-up to their #1), **fixed upstream in `ce4e373`** and confirmed across two real
      power-cycles on hardware. Our PR became redundant (maintainer fixed it directly).
- [x] Polish: add a LICENSE (CC BY 4.0)
- [x] ~~Contribute a note to elektricM docs~~ — dropped: they added a runtime-UMR option and a
      Bazzite section themselves (Sept 2026), and the gotcha is fixed upstream
- [x] Oct 2026 refresh: duggasco archive, live-manager breaking changes, governor v0.4.14,
      llama.cpp release tags, new references
- [x] Re-capture `status` / masking output on hardware with the current live-manager version
      (`a929085`, Oct 2026), including live-disabling a stock WGP and masking-cost measurements
- [x] Re-check the governor sweep on v0.4.14 (single methodology, live sampling)
- [ ] Re-run the sweep after fixing the test board's airflow (idle temps were high in Oct 2026)
- [ ] Optional: a tested Arch / Omarchy page (runtime-UMR with `umr` from AUR)
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
