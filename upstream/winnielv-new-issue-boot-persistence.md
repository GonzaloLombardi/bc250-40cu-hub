# DRAFT issue for WinnieLV/bc250-cu-live-manager (option 1b — new issue, references #1)

> **Status: FILED** as https://github.com/WinnieLV/bc250-cu-live-manager/issues/3
> Verified against `main` script SHA256 `9443d292…0101c` (byte-identical to the tested build).
> Kept here for the record; the "Notes for us" section below was not part of the filed issue.

---

**Title:** Boot persistence breaks when the DRI instance changes between boots (persisted `UMR_INSTANCE` overrides auto-detect)

**Body:**

### Context
This is a follow-up to #1 (*UMR register writes fail when GPU is not at debugfs dri/0*) and
the fix in `3c583fe` ("handle non-zero DRI instance and persist service settings") — thanks
for that, the interactive auto-detection works great. This reports a **residual case the fix
doesn't cover**: a board whose DRI instance is **not stable across boots**.

In #1 the instance was *stably* non-zero (always `dri/1`), so persisting `UMR_INSTANCE=1`
solved it. On my board the instance **flips between boots** (`/dev/dri/card1` ⇄ `card0`,
i.e. umr instance `1` ⇄ `0`, notably after a full power-cycle). Because the saved instance is
persisted and **takes priority over auto-detection**, the boot service runs `umr -i <stale>`
and silently falls back to 24 CU.

### Environment
- Bazzite 44 (Fedora Atomic / rpm-ostree), kernel `7.0.9-ogc3.2.fc44`
- `umr` 1.0.11, single BC-250 (`1002:13fe`)
- Installed via `write-service-table` + `install-service` (the documented persistence flow)

### Root cause (current `main`)
1. `write_service_table` bakes the resolved instance into the config — `UMR_INSTANCE=$UMR_INSTANCE` (line ~538).
2. The unit loads it at boot — `EnvironmentFile=-$SERVICE_CONF` → `ExecStart=… --yes apply-service` (lines ~504/506).
3. `select_umr_instance` prefers any non-empty `UMR_INSTANCE` and **returns before** calling
   `detect_umr_instance` (line ~195): `if [ -n "$UMR_INSTANCE" ]; then … return 0; fi`.

So at boot the EnvironmentFile sets `UMR_INSTANCE` (non-empty) → auto-detection is skipped →
the stale instance is used. When the instance changed, the register read fails.

### Reproduction
1. `enable all` → `write-service-table` → `install-service` while the GPU is instance 1.
   Saved config contains `UMR_INSTANCE=1`.
2. Full power-cycle; the GPU comes up as `card0` (instance 0).
3. Boot service fails; board stays at 24 CU.

### Evidence (captured on hardware)

<details><summary>1 — service failed on a cold boot</summary>

```text
$ systemctl is-active bc250-cu-live-manager.service
failed
$ journalctl -u bc250-cu-live-manager.service -b
[ERR ] failed to read cyan_skillfish.gfx1013.mmSPI_PG_ENABLE_STATIC_WGP_MASK with umr.
bc250-cu-live-manager.service: Main process exited, code=exited, status=1/FAILURE
Failed to start bc250-cu-live-manager.service - BC-250 CU saved enumeration and dispatch.

$ grep UMR_INSTANCE /etc/bc250-cu-live-manager.conf
UMR_INSTANCE=1
```
</details>

<details><summary>2 — the DRI instance had flipped to 0 (saved config said 1)</summary>

```text
$ ls /dev/dri | grep card          # earlier boots showed card1
card0
$ for d in /sys/kernel/debug/dri/[0-9]*; do echo "$d -> $(cat $d/name)"; done
/sys/kernel/debug/dri/0 -> amdgpu dev=0000:01:00.0 unique=0000:01:00.0
/sys/kernel/debug/dri/128 -> amdgpu dev=0000:01:00.0 unique=0000:01:00.0

$ sudo umr -i 1 -r cyan_skillfish.gfx1013.mmSPI_PG_ENABLE_STATIC_WGP_MASK -b 0 0 0xffffffff
[ERROR]: ASIC not found or compatible (instance=1, did=ffffffffffffffff)
$ sudo umr -i 0 -r cyan_skillfish.gfx1013.mmSPI_PG_ENABLE_STATIC_WGP_MASK -b 0 0 0xffffffff
gfx1013.mmSPI_PG_ENABLE_STATIC_WGP_MASK => 0x00000007
```
</details>

<details><summary>3 — fix (blank UMR_INSTANCE → auto-detect) works on both instances</summary>

```text
# After: sudo sed -i 's/^UMR_INSTANCE=.*/UMR_INSTANCE=/' /etc/bc250-cu-live-manager.conf
# boot where GPU = instance 0:
[ OK ] dispatch registers updated (40/40 CUs target)
  UMR inst   : 0 (auto)
  SPI total  : 40/40 CUs

# next boot, GPU flipped back to instance 1 — auto-detect handled it:
$ ls /dev/dri | grep card
card1
[ OK ] dispatch registers updated (40/40 CUs target)
  UMR inst   : 1 (auto)
  SPI total  : 40/40 CUs
```
</details>

### How this differs from #1
#1 = instance stably non-zero → persisting it is the fix. This = instance **not stable** →
persisting it is the *cause*; the already-present `detect_umr_instance` would handle it if it
weren't short-circuited by the saved value at boot.

### Suggested fix (either)
1. **Minimal:** in `write_service_table`, write `UMR_INSTANCE=` (empty) instead of the
   resolved instance, so `apply-service` auto-detects each boot. Keep persisting `UMR` and
   `UMR_ASIC`. (`-i`/`--umr-instance` remains available as a manual override.)
2. **Keep override semantics:** in `select_umr_instance`, when invoked by `apply-service`,
   run `detect_umr_instance` first and use the persisted `UMR_INSTANCE` only as a fallback
   when detection fails.

Happy to send a PR for whichever you prefer.

---

## Notes for us (not part of the issue)
- The instance flip is non-deterministic (can't force on demand), but we have logs of the
  GPU enumerating as both 0 and 1, and the failure + fix on each.
- Likely cause of the flip on Bazzite: boot framebuffer (simpledrm/efifb) vs amdgpu probe
  order grabbing `card0` on some boots — worth mentioning only if asked.
- After filing: update the hub README roadmap, and reword the elektricM docs note to
  reference both #1 and this issue before opening that PR (if we still do it).
