# Selective WGP / CU masking on the BC-250 (scattered-harvest boards)

Not every BC-250 has the "lucky" contiguous harvest (24 CUs = WGP0–2 on, WGP3–4 off on every
row). Some boards have **scattered** disabled units, and some have a genuinely **faulty** WGP
that crashes the GPU when routed. For those, you don't enable all 40 — you enable the **good**
WGPs and mask the bad ones, landing somewhere like 36 or 38 CUs that's stable.

The harvest map is only a hint. Community reports
([elektricM/amd-bc250-docs#57](https://github.com/elektricM/amd-bc250-docs/issues/57)) include
contiguous boards with bad CUs and scattered boards that run all 40 cleanly. So whatever your
map looks like, stress-test after unlocking. The bisection workflow below works for any board.

This uses the same runtime-UMR tool as the [main unlock guide](bazzite-40cu-runtime-umr.md):
[`WinnieLV/bc250-cu-live-manager`](https://github.com/WinnieLV/bc250-cu-live-manager).

> ← Back to the [hub README](../README.md).

---

## Addressing: SE.SH.WGP

The GPU is 4 shader-array rows × 5 WGPs × 2 CUs:

| Row | `SE.SH` | WGP0 | WGP1 | WGP2 | WGP3 | WGP4 |
|---|---|---|---|---|---|---|
| SE0.SH0 | `0.0` | CU0–1 | CU2–3 | CU4–5 | CU6–7 | CU8–9 |
| SE0.SH1 | `0.1` | … | | | | |
| SE1.SH0 | `1.0` | … | | | | |
| SE1.SH1 | `1.1` | … | | | | |

- **WGP is the unit of control** — one WGP = two CUs; you can't toggle a single CU.
- `disable-wgp 1.0.4` = SE1, SH0, WGP4 (CU8–9). To go from a CU id to its WGP, divide by 2.
- The `enable-cu` / `disable-cu` aliases were **removed** upstream in
  [`046e36b`](https://github.com/WinnieLV/bc250-cu-live-manager/commit/046e36b) (June 2026).
  Use the WGP commands.
- The per-row SPI mask is a 5-bit value: `0x1f` = all 5 WGPs on, `0x0f` = WGP4 off,
  `0x07` = stock (WGP0–2 only), etc.

---

## Read your map first

```bash
sudo ~/bc250-cu-live-manager.sh status
```

A **scattered** board looks like this (note the gaps aren't all at the end):

```
  | SE0.SH0 |  D+  |  D+  |  D+  |  --  |  --  |
  | SE0.SH1 |  D+  |  --  |  D+  |  --  |  S+  |   <- non-contiguous
  | SE1.SH0 |  D+  |  D+  |  D+  |  --  |  --  |
  | SE1.SH1 |  D+  |  D+  |  D+  |  --  |  --  |
```

Legend (current versions): `D+` = in the driver's boot topology and routed, `S+` = routed via
SPI by you (not in the driver topology), `D!` = in the driver topology but switched off by
you, `--` = off.

---

## Commands

```bash
# Enable / disable specific WGPs (space- or comma-separated lists)
sudo ~/bc250-cu-live-manager.sh enable-wgp 0.1.3 1.1.3
sudo ~/bc250-cu-live-manager.sh disable-wgp 1.0.4

# Whole-board presets
sudo ~/bc250-cu-live-manager.sh enable all              # all 40
sudo ~/bc250-cu-live-manager.sh stock-dispatch          # back to 24 (driver topology)
sudo ~/bc250-cu-live-manager.sh disable all             # turn off every dispatch WGP

# Interactive editor (arrows/hjkl move, Space toggles, Enter applies)
sudo ~/bc250-cu-live-manager.sh table
```

Always preview with `--dry-run` first. Real output of disabling one harvested WGP (live-manager
`a929085`, Oct 2026; CC writes trimmed):

```text
$ sudo ./bc250-cu-live-manager.sh disable-wgp 1.0.4 --dry-run
[ OK ] disabled SE1 SH0 WGP4 (CU8-CU9)
dry-run: /usr/bin/umr -i 1 -w cyan_skillfish.gfx1013.mmSPI_PG_ENABLE_STATIC_WGP_MASK 0x1f -b 0 0 0xffffffff
dry-run: /usr/bin/umr -i 1 -w cyan_skillfish.gfx1013.mmSPI_PG_ENABLE_STATIC_WGP_MASK 0x1f -b 0 1 0xffffffff
dry-run: /usr/bin/umr -i 1 -w cyan_skillfish.gfx1013.mmSPI_PG_ENABLE_STATIC_WGP_MASK 0x0f -b 1 0 0xffffffff   <- SE1.SH0 -> 0x0f
dry-run: /usr/bin/umr -i 1 -w cyan_skillfish.gfx1013.mmSPI_PG_ENABLE_STATIC_WGP_MASK 0x1f -b 1 1 0xffffffff
dry-run: /usr/bin/umr -i 1 -w cyan_skillfish.gfx1013.mmRLC_PG_ALWAYS_ON_WGP_MASK 0x1f
[ OK ] dispatch registers updated (38/40 CUs target)
```

So that one change lands the board at **38/40 CUs**, with WGP4 of SE1.SH0 masked out. The
removed alias now fails cleanly: `disable-cu 1.0.8` → `[ERR ] unknown command: disable-cu`.

### What masking costs: the slowest row sets the pace

Masking a WGP costs **more than its share** of throughput. Measured on our board (pp512,
Qwen2.5-3B Q4_K_M, governor default range, Oct 2026):

| Mask | CUs | Rows at 8 CUs | pp512 (tok/s) | vs 40 CU |
|---|---|---|---|---|
| all on | 40 | 0 | 1072 | 100 % |
| `disable-wgp 1.0.4` (harvested) | 38 | 1 | 966 | 90 % |
| `disable-wgp 0.0.0` (stock) | 38 | 1 | 965 | 90 % |
| `disable-wgp 0.0.4 0.1.4` | 36 | 2 | 907 | 85 % |
| WGP4 off on all 4 rows | 32 | 4 | 906 | 85 % |
| stock (`stock-dispatch`) | 24 | — | 685 | 64 % |

Two lessons:

- **It doesn't matter which WGP in a row you mask.** Stock WGP0 and unlocked WGP4 cost the same.
- **Uneven rows are bottlenecked by the shortest one.** With two rows trimmed you're already
  at 32-CU speed, and trimming the other two rows costs almost nothing more. A 38-CU result is
  worth ~90 %, not 95 %, and 36 is worth the same as 32.

(One board, one workload. Compute-heavy kernels that split work evenly across shader arrays
behave like this; your mileage may vary with other loads.)

---

## Driver-active (stock) WGPs

The 24 stock CUs (WGP0–2) are **in the driver's boot topology**. Older versions of the tool
refused to touch them at runtime (`refusing to disable SE0 SH0 WGP0; it is active in driver
topology`). **That lock was removed** in
[`046e36b`](https://github.com/WinnieLV/bc250-cu-live-manager/commit/046e36b): live routing can
now disable any WGP pair, stock ones included, and the dashboard shows them as `D!`.

What that means in practice:

- The only change is SPI dispatch: the driver still believes those CUs exist
  (`active_cu_number` doesn't change). That makes this a way to **stop sending work to a stock
  WGP you suspect is faulty**, without a reboot.
- **Tested on our board (Oct 2026):** `disable-wgp 0.0.0` shows the WGP as `D!`
  (`SE0.SH0 | D! | D+ | D+ | S+ | S+ | 0x1e`), the board stays stable through a llama-bench run
  with no amdgpu errors in `dmesg`, and `enable all` brings it back. Throughput is the same as
  masking a harvested WGP in the same row (see the table above). Still use `--dry-run` first and
  keep a remote shell.
- For a boot-time mask the driver itself respects, the kernel-patch path still has the
  `disable_cu=` modparam (see [duggasco](https://github.com/duggasco/bc250-40cu-unlock), now
  archived).

---

## Finding the bad WGP (bisection workflow)

If `enable all` is unstable on your board:

1. `enable all`, then stress-test (the `llama-bench` loop from the unlock guide, or
   furmark/OCCT). Watch `dmesg` for GPU resets.
2. If it crashes, `stock-dispatch` to recover, then enable the harvested WGPs **one row at a
   time** (`enable-wgp 0.0.3 0.0.4`, test, then the next row…).
3. When a specific row/WGP triggers the crash, leave that one masked and enable the rest.
   Typical stable landing points are 36 or 38 CUs. Keep the
   [row bottleneck](#what-masking-costs-the-slowest-row-sets-the-pace) in mind when comparing them.
4. duggasco also ships a per-WGP **health test** (`bc250-cu-health-test.sh` + `bc250-cu-mask.sh`)
   that automates this on the kernel-patch path — useful as a cross-reference. The repo is
   archived but still clones.
5. If the crash persists with every harvested WGP masked, the culprit may be a **stock** WGP.
   Current versions let you mask those live too (see above).

---

## Persisting a custom mask

Once you've found a stable subset (e.g. 38/40):

```bash
# with your desired WGPs enabled and the bad one(s) disabled:
sudo ~/bc250-cu-live-manager.sh write-service-table --yes
sudo ~/bc250-cu-live-manager.sh install-service --yes
```

The saved profile stores your exact per-row masks (e.g. `0x1f,0x1f,0x0f,0x1f`), not just
"all on", so a masked layout persists correctly. Re-run `write-service-table` after any table
change. `status` tells you when the saved boot table is out of date.

> On installs from before June 2026 the boot service can break when the DRI instance changes
> between boots. Update the script; see
> [the note in the unlock guide](bazzite-40cu-runtime-umr.md#older-builds-stale-umr_instance-breaks-boot-persistence).

Revert anytime with `stock-dispatch` (live) or `uninstall-service` + reboot (permanent).
