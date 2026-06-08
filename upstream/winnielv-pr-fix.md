# DRAFT PR for WinnieLV/bc250-cu-live-manager (the fix for issue #3)

> **Status: SUPERSEDED — do not open.** The maintainer fixed this directly in
> [`ce4e373`](https://github.com/WinnieLV/bc250-cu-live-manager/commit/ce4e373) (same approach:
> `apply-service` auto-detects each run, `write-service-table` writes `UMR_INSTANCE=` empty).
> We confirmed the official fix on two real power-cycles ([issue #3 comment](https://github.com/WinnieLV/bc250-cu-live-manager/issues/3#issuecomment-4650483875)).
> The fork branch `GonzaloLombardi:fix-unstable-dri-instance` (commit `5e93804`) is kept only
> for the record. Draft body below is historical.

**Base:** `WinnieLV/bc250-cu-live-manager:main`
**Head:** `GonzaloLombardi:fix-unstable-dri-instance`
**Title:** `fix(umr): re-detect DRI instance at boot instead of trusting persisted value`

---

**Body:**

Fixes #3.

`write-service-table` persists the resolved `UMR_INSTANCE` into the service `EnvironmentFile`,
and `select_umr_instance` treats any non-empty `UMR_INSTANCE` as authoritative — returning
before `detect_umr_instance` runs. But the DRI instance number isn't stable across boots
(`/dev/dri/card0` ⇄ `card1` after a power-cycle), so on a boot where it changed the service
runs `umr -i <stale>`, fails to read the registers, and silently falls back to 24 CU.

### Change
`select_umr_instance` now:
- still lets an **explicit CLI override** (`--umr-instance` / `-i`, `source = cli`) win;
- otherwise **prefers live detection** (`detect_umr_instance`), which matches the BC-250 BDF
  in `/sys/kernel/debug/dri/` and is correct every boot;
- uses the persisted/env value only as a **fallback** when detection can't find the board.

This also **self-heals existing installs** whose config already baked a now-stale instance —
no need to re-run `write-service-table`. 12 lines, one function, no behavior change for the
interactive `-i` path.

### Verification (Bazzite 44, kernel `7.0.9-ogc3.2.fc44`, umr 1.0.11, BC-250)
- `UMR_INSTANCE=0` baked while the GPU enumerated as instance 1:
  - **before:** boot service → `failed to read … with umr`, board at 24 CU;
  - **after (this PR):** boot service self-heals → `dispatch registers updated (40/40)`,
    `UMR inst : 1 (auto)`, verified across a full reboot.
- `--umr-instance 0` still honored (uses 0, source `cli`); `--umr-instance 1` works (`cli`).
- Normal auto-detect unchanged when nothing is persisted.

`bash -n` clean. Only `bc250-cu-live-manager.sh` changed.

---

## To open it (when ready)

```bash
gh pr create \
  --repo WinnieLV/bc250-cu-live-manager \
  --base main \
  --head GonzaloLombardi:fix-unstable-dri-instance \
  --title "fix(umr): re-detect DRI instance at boot instead of trusting persisted value" \
  --body-file <this body>
```

> Note: the maintainer offered two fix shapes in #3. This PR implements the robust one
> (re-detect + fallback). If they prefer the minimal one (write `UMR_INSTANCE=` empty in
> `write_service_table`), that's a one-line alternative we can swap in.
