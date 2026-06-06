# Draft issue for WinnieLV/bc250-cu-live-manager

> Ready-to-paste GitHub issue. Repo: https://github.com/WinnieLV/bc250-cu-live-manager
> Decide before filing whether to also offer a PR (suggested fix below is small).

---

**Title:** `write-service-table` bakes a volatile `UMR_INSTANCE` → boot service fails after DRI renumbering (drops back to 24 CU)

**Body:**

### Summary
`write-service-table` records the **current** umr DRI instance into
`/etc/bc250-cu-live-manager.conf` as `UMR_INSTANCE=<N>`. But the DRI instance number is **not
stable across boots** — the same board enumerates as `/dev/dri/card1` (instance 1) on one boot
and `card0` (instance 0) on another (reproducible across a full power-cycle). When the saved
number no longer matches, the boot service runs `umr -i <wrong>`, fails to read the registers,
and the board silently stays at **24 CU**.

### Environment
- Bazzite 44 (Fedora Atomic / rpm-ostree), kernel `7.0.9-ogc3.2.fc44`
- `umr` 1.0.11, BC-250 (`1002:13fe`), single GPU
- live manager installed as the systemd boot service

### Repro
1. `enable all` → `write-service-table` → `install-service` while the GPU is instance 1.
   Conf now contains `UMR_INSTANCE=1`.
2. Full power-cycle. GPU comes back as `/dev/dri/card0` (instance 0).
3. Boot service fails.

### Observed
```
systemctl is-active bc250-cu-live-manager.service   # failed
journalctl -u bc250-cu-live-manager.service -b:
  [ERR ] failed to read cyan_skillfish.gfx1013.mmSPI_PG_ENABLE_STATIC_WGP_MASK with umr.
  bc250-cu-live-manager.service: Main process exited, code=exited, status=1/FAILURE
```
Confirming the instance flip on the failing boot:
```
$ ls /dev/dri | grep card           # card0  (was card1 previously)
$ sudo umr -i 1 -r cyan_skillfish.gfx1013.mmSPI_PG_ENABLE_STATIC_WGP_MASK -b 0 0 0xffffffff
  [ERROR]: ASIC not found or compatible (instance=1, did=ffffffffffffffff)
$ sudo umr -i 0 -r cyan_skillfish.gfx1013.mmSPI_PG_ENABLE_STATIC_WGP_MASK -b 0 0 0xffffffff
  gfx1013.mmSPI_PG_ENABLE_STATIC_WGP_MASK => 0x00000007
```

### Root cause
The persisted `UMR_INSTANCE` overrides the script's own auto-detection (which only runs when
`UMR_INSTANCE` is empty). Auto-detection (`detect_umr_instance`, matching the BC-250 BDF in
`/sys/kernel/debug/dri/`) would pick the correct instance every boot — but the baked value
short-circuits it.

### Workaround (verified)
Blank the baked instance so the service auto-detects each boot:
```bash
sudo sed -i 's/^UMR_INSTANCE=.*/UMR_INSTANCE=/' /etc/bc250-cu-live-manager.conf
sudo systemctl restart bc250-cu-live-manager.service
```
Verified the service then applies 40/40 correctly across boots enumerating the GPU as both
instance 0 and instance 1.

### Suggested fix (one of)
1. **`write_service_table`**: write `UMR_INSTANCE=` (empty) instead of the current instance,
   so `apply-service` always auto-detects. Simplest, robust.
2. **`apply-service`**: ignore the persisted instance and always re-run `detect_umr_instance`
   at boot (the BDF is stable even when the DRI number isn't); keep `UMR_INSTANCE` only as an
   optional manual override.
3. At minimum, document the pitfall in the README's persistence section.

Happy to send a PR for (1) or (2) if you have a preference.
