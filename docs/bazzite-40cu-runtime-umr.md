# Unlocking all 40 CUs on the AMD BC-250 under Bazzite (runtime-UMR)

A tested, end-to-end guide to re-enabling the 16 harvested compute units (24 → 40 CUs)
on the AMD BC-250 (Cyan Skillfish, `gfx1013`, PCI `1002:13fe`) running **Bazzite**,
an immutable Fedora Atomic OS.

> ← Back to the [hub README](../README.md) for the full reference index and the other methods.

> **TL;DR** — On an atomic distro you do **not** patch/replace the kernel. You use the
> **runtime-UMR** method ([`WinnieLV/bc250-cu-live-manager`](https://github.com/WinnieLV/bc250-cu-live-manager)),
> which writes the dispatch registers from userspace after boot. No kernel rebuild,
> no version pinning, survives kernel updates, reverts on reboot. Verified **~1.55×**
> prompt-processing throughput on a real workload.

---

## Why not the "normal" kernel-patch method on Bazzite?

The reference project, [`duggasco/bc250-40cu-unlock`](https://github.com/duggasco/bc250-40cu-unlock),
patches the `amdgpu` kernel module and installs it into `/usr/lib/modules`. That works on
mutable distros, but on **Bazzite / Fedora Atomic** it fights the OS design:

- `/usr/lib/modules` is **read-only** (part of the ostree deployment). Copying a `.ko` there
  does not persist across image updates.
- Prebuilt patched-kernel RPMs that circulate in the community are pinned to a **specific
  kernel build** (e.g. `6.17.7-ba29.fc43`). If your Bazzite is newer (e.g.
  `7.0.9-ogc3.2.fc44`), `rpm-ostree override replace` would **downgrade your kernel** and
  mix an fc43 kernel onto an fc44 image — fragile, and it pins you off kernel updates.

> ⚠️ **The biggest pitfall:** grabbing community `bazzite-bc250cu-rpms-*.7z` and running
> `rpm-ostree override replace` **without checking that the kernel version matches your
> running image**. Check `uname -r` first. If it doesn't match, **don't** — use the
> runtime-UMR method below instead.

> **Note:** duggasco archived `bc250-40cu-unlock` on 17 September 2026. It still clones, but
> nothing in it will be fixed for later kernels. The runtime-UMR route below doesn't depend on it.

The community docs ([elektricM/amd-bc250-docs](https://elektricm.github.io/amd-bc250-docs/system/40cu-unlock/))
recommend the runtime-UMR approach for rpm-ostree systems. This guide is the concrete,
tested walkthrough.

**The other working option on Bazzite: rebase to a prebuilt image.**
[62fixolab/Latest-Bazzite-AMD-BC-250-Patched-Images](https://github.com/62fixolab/Latest-Bazzite-AMD-BC-250-Patched-Images)
builds Deck / GNOME / KDE images on the official Bazzite `stable` base, with the SMU governor
preinstalled, plus `-40cu` variants that bundle the live manager behind `ujust bc250-cu-*`
commands. Unlike the `.7z` RPM sets, these track Bazzite updates. Their README calls the
`-40cu` images **experimental**, and Bazzite doesn't support rebasing between desktop variants,
so stay on the variant you already run. We haven't tested them. This guide sticks to layering
`umr` on the stock image.

---

## How the runtime unlock works

Instead of changing the driver at init, the live manager writes three GPU registers via
`umr` (User Mode Register tool) after boot, per shader array (SE/SH):

| Register | Stock | Unlocked | Purpose |
|---|---|---|---|
| `mmCC_GC_SHADER_ARRAY_CONFIG` | `0xfff80000` | `0xffe00000` (mask cleared) | CU harvest mask |
| `mmSPI_PG_ENABLE_STATIC_WGP_MASK` | `0x07` | `0x1f` | WGP dispatch routing |
| `mmRLC_PG_ALWAYS_ON_WGP_MASK` | — | `0x1f` | keep WGPs powered |

Granularity is the **WGP** (Work-Group Processor = 2 CUs). The BC-250 has 5 WGPs per row
across 4 rows (SE0.SH0, SE0.SH1, SE1.SH0, SE1.SH1); stock has WGP0–2 on (6 CUs/row × 4 =
24) and WGP3–4 harvested. Unlocking routes all 5 WGPs/row → 40 CUs.

> Note: `dmesg | grep active_cu_number` will still report **24** after the runtime unlock —
> that number is the driver's *boot enumeration*, which this method intentionally does not
> rewrite. The proof the extra CUs do real work is a **compute benchmark** (see below).

---

## Prerequisites

- An AMD BC-250 board confirmed via `lspci -nn | grep 13fe`.
- Bazzite (any recent version). Tested on **Bazzite 44 (Kinoite)**: first on `44.20260608` /
  kernel 7.0.9-ogc3.2 (June 2026), re-tested on `44.20260929` / kernel 7.2.7-ogc1.1 /
  Mesa 26.2.2 (Oct 2026) with live-manager `a929085`. The `umr` layer and the boot service
  carried over the image update untouched.
- Sudo/root, a network connection, and the ability to reboot once (to layer `umr`).
- A **remote shell fallback** (SSH from another machine) is strongly recommended in case a
  register write hangs the GPU — you can then `reboot` to recover.

Confirm `umr` is packaged for your Fedora base (it is on fc44):

```bash
dnf repoquery umr      # expect: umr-1.0.11-2.fc44.x86_64 (or similar)
```

---

## Step 0 — Safety net (rollback pin)

```bash
rpm-ostree status              # note your current deployment
sudo ostree admin pin 0        # pin the running deployment as a permanent fallback
```

You can always return to this exact state from the GRUB boot menu or `rpm-ostree rollback`.

## Step 1 — Install `umr` (one reboot)

`umr` is layered as an rpm-ostree package (host-level), so it needs a reboot to activate.

```bash
sudo rpm-ostree install umr
sudo systemctl reboot
```

After reboot, verify:

```bash
command -v umr && umr --version 2>/dev/null; rpm -q umr
```

> Alternative: once you have the script (Step 2), `sudo ~/bc250-cu-live-manager.sh install-umr`
> does the same layering for you (it detects rpm-ostree, stages `umr`, and asks you to reboot).
> It also handles apt (building from source on Debian), pacman/paru and dnf.
>
> ⚠️ **Only run it if `umr` isn't installed yet.** Its "already installed" check only looks at
> dpkg and pacman, so on Bazzite with `umr` already layered it calls `rpm-ostree install umr`
> again and fails with `[ERR ] rpm-ostree could not install umr` (rpm-ostree:
> `Package/capability 'umr' is already requested`). Nothing is changed, so it's harmless, but
> misleading. Check with `rpm -q umr` instead. (Tested on `a929085`, Oct 2026.)

## Step 2 — Get the live manager (verified)

```bash
curl -fL -o ~/bc250-cu-live-manager.sh \
  https://raw.githubusercontent.com/WinnieLV/bc250-cu-live-manager/refs/heads/main/bc250-cu-live-manager.sh
chmod +x ~/bc250-cu-live-manager.sh
```

> The script is plain Bash, gated on PCI `13fe`, refuses writes on other hardware, supports
> `--dry-run`, and only touches the three documented registers for CU routing. Read it before
> running with root — that's good hygiene for anything that writes GPU registers.
>
> Current versions re-launch themselves with `sudo` when a command needs root. The examples
> here keep `sudo` explicit anyway. Since mid-2026 the script also has a separate
> `cpu-unlock` command (6c/12t → 8c/16t via the SMU), covered in the
> [8-core unlock page](cpu-8core-unlock-bazzite.md).

## Step 3 — Read your harvest map (read-only)

```bash
sudo ~/bc250-cu-live-manager.sh status
```

Look at the table. The **lucky / contiguous** case looks like this (WGP3–4 off on every row):

```
  Legend     : D+ driver+routed, S+ SPI+routed, D! driver+off, -- off

  +---------+------+------+------+------+------+------+------------+--------+
  | Row     | WGP0 | WGP1 | WGP2 | WGP3 | WGP4 | SPI  | CC         | CUs    |
  |         | 0-1  | 2-3  | 4-5  | 6-7  | 8-9  |      |            |        |
  +---------+------+------+------+------+------+------+------------+--------+
  | SE0.SH0 |  D+  |  D+  |  D+  |  --  |  --  | 0x07 | 0xfff80000 |   6/10 |
  | SE0.SH1 |  D+  |  D+  |  D+  |  --  |  --  | 0x07 | 0xfff80000 |   6/10 |
  | SE1.SH0 |  D+  |  D+  |  D+  |  --  |  --  | 0x07 | 0xfff80000 |   6/10 |
  | SE1.SH1 |  D+  |  D+  |  D+  |  --  |  --  | 0x07 | 0xfff80000 |   6/10 |
  +---------+------+------+------+------+------+------+------------+--------+

  CUs active & routed  : 24/40
```

(Older versions printed `SPI total : 24/40 CUs` instead of the last line. If you've already
unlocked once this boot and gone back with `stock-dispatch`, CC reads `0xffe00000` instead:
`stock-dispatch` only restores the SPI/RLC dispatch masks, which is what actually gates the
extra CUs. A reboot without the service brings CC back to `0xfff80000`.)

- **Contiguous (as above):** the common case. `enable all` is the normal next step.
- **Scattered** (disabled WGPs interspersed): use **selective WGP masking** (`enable-wgp` /
  `disable-wgp`, or the `table` editor) and test row by row.

Treat the map as a hint, not a verdict. Community reports
([elektricM/amd-bc250-docs#57](https://github.com/elektricM/amd-bc250-docs/issues/57)) include
contiguous boards with bad CUs and scattered boards that run all 40. Whatever yours shows,
stress-test after unlocking (see [selective masking](selective-wgp-masking.md#finding-the-bad-wgp-bisection-workflow)).

## Step 4 — Preview, then apply

```bash
# Dry-run: prints the exact umr writes WITHOUT executing them
sudo ~/bc250-cu-live-manager.sh enable all --dry-run

# Apply for real (live; reverts on reboot until you persist it)
sudo ~/bc250-cu-live-manager.sh enable all --yes

# Verify: every row should now be 0x1f / 0xffe00000, 40/40 routed
sudo ~/bc250-cu-live-manager.sh status
```

Expected after unlock (real capture, live-manager `a929085`, Oct 2026):

```
  UMR        : /usr/bin/umr
  UMR inst   : 1 (auto)
  ASIC       : cyan_skillfish.gfx1013
  amdgpu     : bc250_cc_write_mode=not exposed, active_cu_number=24
  CPU        : 12 threads present, 12 online; mask not probed (governor active)
  Service    : enabled
  Boot sync  : current table saved
  Source     : SPI dispatch masks + amdgpu boot CU map
  Legend     : D+ driver+routed, S+ SPI+routed, D! driver+off, -- off

  +---------+------+------+------+------+------+------+------------+--------+
  | Row     | WGP0 | WGP1 | WGP2 | WGP3 | WGP4 | SPI  | CC         | CUs    |
  |         | 0-1  | 2-3  | 4-5  | 6-7  | 8-9  |      |            |        |
  +---------+------+------+------+------+------+------+------------+--------+
  | SE0.SH0 |  D+  |  D+  |  D+  |  S+  |  S+  | 0x1f | 0xffe00000 |  10/10 |
  | SE0.SH1 |  D+  |  D+  |  D+  |  S+  |  S+  | 0x1f | 0xffe00000 |  10/10 |
  | SE1.SH0 |  D+  |  D+  |  D+  |  S+  |  S+  | 0x1f | 0xffe00000 |  10/10 |
  | SE1.SH1 |  D+  |  D+  |  D+  |  S+  |  S+  | 0x1f | 0xffe00000 |  10/10 |
  +---------+------+------+------+------+------+------+------------+--------+

  CUs active & routed  : 40/40
```

- `S+` = the formerly harvested WGPs, now routed via SPI.
- `active_cu_number=24` is expected (see the note above).
- `Boot sync` tells you whether the saved boot table matches what's live.
- `CPU … mask not probed (governor active)`: the script skips the SMU CPU-mask probe while the
  GPU governor runs, because both talk to the same SMU. Harmless.

## Step 5 — Verify it does real work (benchmark)

`active_cu_number` won't change, so prove the gain with a compute load. A self-contained
prebuilt `llama.cpp` Vulkan binary runs on the host's RADV with no container or reboot:

```bash
# Get the prebuilt Vulkan binary (resolves the newest bNNNN build tag)
mkdir -p ~/llamabench && cd ~/llamabench
TAG=$(curl -fsSL "https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=10" | grep -oE '"tag_name": "b[0-9]+"' | head -1 | cut -d'"' -f4)
echo "llama.cpp build: $TAG"
curl -fsSL -o llama.tar.gz "https://github.com/ggml-org/llama.cpp/releases/download/$TAG/llama-$TAG-bin-ubuntu-vulkan-x64.tar.gz"
tar xzf llama.tar.gz
BIN=$(find . -name llama-bench | head -1); LIB=$(dirname "$BIN")

# A small compute-bound model (prefill/pp512 scales with CU count)
mkdir -p ~/models
curl -fL -o ~/models/qwen2.5-3b-q4.gguf \
  https://huggingface.co/bartowski/Qwen2.5-3B-Instruct-GGUF/resolve/main/Qwen2.5-3B-Instruct-Q4_K_M.gguf

# Benchmark at 40 CU
LD_LIBRARY_PATH="$LIB" "$BIN" -m ~/models/qwen2.5-3b-q4.gguf -p 512 -n 0 -ngl 99

# A/B: drop to 24 CU, re-run, then restore 40 CU
sudo ~/bc250-cu-live-manager.sh stock-dispatch --yes
LD_LIBRARY_PATH="$LIB" "$BIN" -m ~/models/qwen2.5-3b-q4.gguf -p 512 -n 0 -ngl 99
sudo ~/bc250-cu-live-manager.sh enable all --yes
```

**Reference result** (BC-250 @ governor default range 1000–1850 MHz, Qwen2.5-3B Q4_K_M,
llama.cpp `b9538` Vulkan; [`benchmark-40cu.sh`](../scripts/benchmark-40cu.sh) does this A/B for you):

| Config | Jun 2026 (44.20260608, kernel 7.0.9) | Oct 2026 (44.20260929, kernel 7.2.7, Mesa 26.2.2) |
|---|---|---|
| 40 CU | **1062** tok/s (**1.55×**) | **1072** tok/s (**1.56×**) |
| 24 CU (stock) | 684 tok/s | 685 tok/s |

The ratio held across four months of kernel/Mesa/governor updates. The download snippet above
was re-run on the board in October 2026: it resolved `b11382`, and that build gives 1076 tok/s at
40 CU, the same as `b9538`. Newer llama.cpp builds don't move this benchmark. Peak was ~60–72 °C
depending on how warm the board already was, well within limits.

Watch thermals live during any stress test (the `hwmonN` number changes between boots, so
look it up by name):

```bash
HW=$(for h in /sys/class/hwmon/hwmon*; do [ "$(cat $h/name)" = amdgpu ] && echo $h; done)
watch -n1 'echo "$(($(cat '$HW'/temp1_input)/1000))C $(($(cat '$HW'/power1_average)/1000000))W"'
```

## Step 6 — Persist across reboots (optional)

Only after you've confirmed stability:

```bash
sudo ~/bc250-cu-live-manager.sh write-service-table --yes   # saves current 40/40 mask
sudo ~/bc250-cu-live-manager.sh install-service --yes       # systemd oneshot @ boot
systemctl is-enabled bc250-cu-live-manager.service          # -> enabled
```

The service writes the saved mask at every boot. Config lives in
`/etc/bc250-cu-live-manager.conf`; the binary is copied to `/usr/local/bin`
(→ `/var/usrlocal/bin` on Bazzite). Reboot once and re-check `status` to confirm 40/40 is
reapplied automatically.

> ### Older builds: stale UMR_INSTANCE breaks boot persistence
>
> **Only affects installs from before 7 June 2026** (fixed upstream in
> [`ce4e373`](https://github.com/WinnieLV/bc250-cu-live-manager/commit/ce4e373), reported as
> [#3](https://github.com/WinnieLV/bc250-cu-live-manager/issues/3)). Current versions write
> `UMR_INSTANCE=` empty and `apply-service` auto-detects the DRI instance on every boot, so
> there's nothing to do. (Re-confirmed Oct 2026 on `a929085`: across three boots with the service the board
> came up as instance 1, 1 and then 0, and it applied 40/40 every time.)
>
> On older builds, `write-service-table` baked the current instance (e.g. `UMR_INSTANCE=1`)
> into the config. The DRI number isn't stable across boots (a power-cycle can flip
> `card1` ↔ `card0`), so the service then failed with
> `failed to read cyan_skillfish.gfx1013.mmSPI_PG_ENABLE_STATIC_WGP_MASK with umr` and left
> you at 24 CU. **The real fix is to update:** re-download the script (Step 2) and re-run
> `install-service --yes`, which replaces the copy in `/usr/local/bin`. If you can't update,
> blank the baked value after every `write-service-table`:
> ```bash
> sudo sed -i 's/^UMR_INSTANCE=.*/UMR_INSTANCE=/' /etc/bc250-cu-live-manager.conf
> sudo systemctl restart bc250-cu-live-manager.service
> sudo ~/bc250-cu-live-manager.sh status   # UMR inst should now read "N (auto)"
> ```

---

## Reverting

```bash
# Live, no reboot — back to 24 CU now:
sudo ~/bc250-cu-live-manager.sh stock-dispatch --yes

# Remove boot persistence (driver topology restores on next boot):
sudo ~/bc250-cu-live-manager.sh uninstall-service && sudo systemctl reboot

# Remove umr layer entirely (optional):
sudo rpm-ostree uninstall umr && sudo systemctl reboot
```

A plain reboot **without** the service installed always returns to stock 24 CU.

`uninstall-service` removes the unit, the copy in `/usr/local/bin` **and the saved boot table**
(`/etc/bc250-cu-live-manager.conf`). To persist again later, re-run `write-service-table`
before (or after) `install-service`. (Full revert cycle tested Oct 2026: uninstall → reboot →
24/40 with CC back to `0xfff80000` → reinstall → 40/40.)

---

## Troubleshooting

- **`umr not found`** — you skipped the reboot after `rpm-ostree install umr`, or an image
  update dropped the layer. Re-install and reboot. The boot service waits for `umr`/render
  nodes, so a missing `umr` means the unlock silently doesn't apply (it won't break boot).
- **`failed to read … with umr` / wrong instance** — pass `-i N` (`--umr-instance`). The
  script auto-detects via `/sys/kernel/debug/dri`, but multi-GPU hosts may need it explicit.
- **Boot service fails / drops back to 24 CU after a (cold) boot** — check
  `journalctl -u bc250-cu-live-manager.service -b`. If it shows `failed to read … with umr`
  and the install is from before June 2026, it's the stale-`UMR_INSTANCE` bug: update the
  script, see [the note in Step 6](#older-builds-stale-umr_instance-breaks-boot-persistence).
- **`failed to read … with umr` right after a system update (Arch/CachyOS)** — the AUR `umr`
  package needs `llvm` at runtime but doesn't declare it. Install `llvm`
  ([bc250-cu-live-manager#11](https://github.com/WinnieLV/bc250-cu-live-manager/issues/11)).
  Doesn't apply to the Fedora `umr` package used here.
- **Crash / freeze right after `enable all`** — likely a board with genuinely defective
  (scattered) WGPs. Reboot to recover, then enable WGPs incrementally and test.
- **No throughput gain** — make sure the workload is GPU/compute-bound and fully offloaded
  (`-ngl 99`). Prefill (`pp512`) scales with CUs; token *generation* is more memory-bound.
- **After a Bazzite update** — the `umr` rpm-ostree layer usually carries over; if not,
  re-layer it. The systemd service and config persist (they're in `/etc` + `/var`).

---

## Credits

- Register research & kernel patch: [duggasco/bc250-40cu-unlock](https://github.com/duggasco/bc250-40cu-unlock) (archived Sept 2026)
- Runtime-UMR live manager: [WinnieLV/bc250-cu-live-manager](https://github.com/WinnieLV/bc250-cu-live-manager)
  (builds on gennro's live-unlock test)
- Community docs hub: [elektricM/amd-bc250-docs](https://github.com/elektricM/amd-bc250-docs)
- GPU governor: [filippor/cyan-skillfish-governor](https://github.com/filippor/cyan-skillfish-governor) (SMU branch)

*No warranty. You are writing low-level GPU registers — keep a remote shell and adequate
cooling.*
