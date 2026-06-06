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

The community docs ([elektricM/amd-bc250-docs](https://elektricm.github.io/amd-bc250-docs/))
explicitly recommend the runtime-UMR approach for immutable systems. This guide is the
concrete, tested walkthrough.

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
- Bazzite (any recent version). Tested on **Bazzite 44 (Kinoite) / kernel 7.0.9-ogc3.2.fc44**.
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

## Step 2 — Get the live manager (verified)

```bash
curl -fL -o ~/bc250-cu-live-manager.sh \
  https://raw.githubusercontent.com/WinnieLV/bc250-cu-live-manager/refs/heads/main/bc250-cu-live-manager.sh
chmod +x ~/bc250-cu-live-manager.sh
```

> The script is plain Bash, gated on PCI `13fe`, refuses writes on other hardware, supports
> `--dry-run`, and only touches the three documented registers. Read it before running with
> root — that's good hygiene for anything that writes GPU registers.

## Step 3 — Read your harvest map (read-only)

```bash
sudo ~/bc250-cu-live-manager.sh status
```

Look at the table. The **lucky / contiguous** case looks like this (WGP3–4 off on every row):

```
| SE0.SH0 |  D+  |  D+  |  D+  |  --  |  --  | 0x07 | 0xfff80000 |   6/10 |
| SE0.SH1 |  D+  |  D+  |  D+  |  --  |  --  | 0x07 | 0xfff80000 |   6/10 |
| SE1.SH0 |  D+  |  D+  |  D+  |  --  |  --  | 0x07 | 0xfff80000 |   6/10 |
| SE1.SH1 |  D+  |  D+  |  D+  |  --  |  --  | 0x07 | 0xfff80000 |   6/10 |
  SPI total  : 24/40 CUs
```

- **Contiguous (as above):** safe to `enable all`.
- **Scattered** (disabled WGPs interspersed): some boards have genuinely defective units.
  Enabling everything risks crashes — use **selective WGP masking** (`enable-wgp` /
  `disable-wgp`, or the `table` editor) and test row by row.

## Step 4 — Preview, then apply

```bash
# Dry-run: prints the exact umr writes WITHOUT executing them
sudo ~/bc250-cu-live-manager.sh enable all --dry-run

# Apply for real (live; reverts on reboot until you persist it)
sudo ~/bc250-cu-live-manager.sh enable all --yes

# Verify: every row should now be 0x1f / 0xffe00000, SPI total 40/40
sudo ~/bc250-cu-live-manager.sh status
```

Expected after unlock:

```
| SE0.SH0 |  D+  |  D+  |  D+  |  S+  |  S+  | 0x1f | 0xffe00000 |  10/10 |
... (×4 rows)
  SPI total  : 40/40 CUs
```

(`S+` = the formerly-harvested WGPs, now routed via SPI.)

## Step 5 — Verify it does real work (benchmark)

`active_cu_number` won't change, so prove the gain with a compute load. A self-contained
prebuilt `llama.cpp` Vulkan binary runs on the host's RADV with no container or reboot:

```bash
# Get the prebuilt Vulkan binary (the tag is resolved to the latest release)
mkdir -p ~/llamabench && cd ~/llamabench
TAG=$(curl -fsSL https://api.github.com/repos/ggml-org/llama.cpp/releases/latest | grep -oE '"tag_name": "[^"]*"' | head -1 | cut -d'"' -f4)
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

**Reference result** (Bazzite 44, BC-250 @ governor default, Qwen2.5-3B Q4_K_M):

| Config | pp512 (tok/s) | Speedup |
|---|---|---|
| 40 CU | **1062** | **1.55×** |
| 24 CU (stock) | 684 | 1.00× |

Peaked at ~60 °C / ~74 W during the run — well within limits.

Watch thermals live during any stress test:

```bash
HW=/sys/class/hwmon/hwmon1   # the one whose `name` is "amdgpu"
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

> ### ⚠️ Important: blank `UMR_INSTANCE` so the service survives every boot
>
> `write-service-table` bakes the **current** umr DRI instance into the config
> (e.g. `UMR_INSTANCE=1`). But the DRI instance number is **not stable across boots** —
> the same board can enumerate as `/dev/dri/card1` (instance 1) on one boot and `card0`
> (instance 0) on the next (notably after a full power-cycle). When that happens, the boot
> service runs `umr -i <wrong>` and fails with:
> ```
> [ERR ] failed to read cyan_skillfish.gfx1013.mmSPI_PG_ENABLE_STATIC_WGP_MASK with umr
> ```
> leaving you silently back at 24 CU. **Fix:** blank the baked instance so the script
> auto-detects the right one each boot (it matches the BC-250 BDF in
> `/sys/kernel/debug/dri/`, which it can read as the root service):
> ```bash
> sudo sed -i 's/^UMR_INSTANCE=.*/UMR_INSTANCE=/' /etc/bc250-cu-live-manager.conf
> sudo systemctl restart bc250-cu-live-manager.service
> sudo ~/bc250-cu-live-manager.sh status   # UMR inst should now read "N (auto)"
> ```
> Do this **after** every `write-service-table` (it re-bakes the instance each time).
> Verified: with `UMR_INSTANCE=` empty, the service correctly applied 40/40 across boots
> that enumerated the GPU as instance 0 *and* instance 1.

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

---

## Troubleshooting

- **`umr not found`** — you skipped the reboot after `rpm-ostree install umr`, or an image
  update dropped the layer. Re-install and reboot. The boot service waits for `umr`/render
  nodes, so a missing `umr` means the unlock silently doesn't apply (it won't break boot).
- **`failed to read … with umr` / wrong instance** — pass `-i N` (`--umr-instance`). The
  script auto-detects via `/sys/kernel/debug/dri`, but multi-GPU hosts may need it explicit.
- **Boot service fails / drops back to 24 CU after a (cold) boot** — the saved
  `UMR_INSTANCE` no longer matches because DRI numbering changed between boots. Blank it so
  the service auto-detects each boot — see the ⚠️ box in [Step 6](#step-6--persist-across-reboots-optional).
  Quick check: `journalctl -u bc250-cu-live-manager.service -b` showing
  `failed to read … with umr` + `systemctl is-active …` = `failed`.
- **Crash / freeze right after `enable all`** — likely a board with genuinely defective
  (scattered) WGPs. Reboot to recover, then enable WGPs incrementally and test.
- **No throughput gain** — make sure the workload is GPU/compute-bound and fully offloaded
  (`-ngl 99`). Prefill (`pp512`) scales with CUs; token *generation* is more memory-bound.
- **After a Bazzite update** — the `umr` rpm-ostree layer usually carries over; if not,
  re-layer it. The systemd service and config persist (they're in `/etc` + `/var`).

---

## Credits

- Register research & kernel patch: [duggasco/bc250-40cu-unlock](https://github.com/duggasco/bc250-40cu-unlock)
- Runtime-UMR live manager: [WinnieLV/bc250-cu-live-manager](https://github.com/WinnieLV/bc250-cu-live-manager)
  (builds on gennro's live-unlock test)
- Community docs hub: [elektricM/amd-bc250-docs](https://github.com/elektricM/amd-bc250-docs)
- GPU governor: [filippor/cyan-skillfish-governor](https://github.com/filippor/cyan-skillfish-governor) (SMU branch)

*No warranty. You are writing low-level GPU registers — keep a remote shell and adequate
cooling.*
