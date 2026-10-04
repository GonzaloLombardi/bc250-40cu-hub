# DRAFT issue for WinnieLV/bc250-cu-live-manager

> **Status: DRAFT, not filed.** Found while re-testing the hub on hardware (Oct 2026).

---

**Title:** `install-umr` fails on rpm-ostree (Bazzite) when `umr` is already layered

**Body:**

### Summary
On Bazzite with `umr` already installed (layered via rpm-ostree), `install-umr` doesn't detect
it and tries to layer it again, which fails:

```text
$ sudo ./bc250-cu-live-manager.sh install-umr
[WARN] rpm-ostree layering is host-level and may affect upgrade workflows on immutable systems.
[ OK ] Installing umr with rpm-ostree (reboot required)...
[ERR ] rpm-ostree could not install umr; try layering it manually and check rpm-ostree output.

$ sudo rpm-ostree install umr
error: Package/capability 'umr' is already requested
$ rpm -q umr
umr-1.0.11-2.fc44.x86_64
```

Nothing is changed (no new deployment is staged), so it's harmless, but the error suggests
something is wrong when everything is fine.

### Cause
`install_umr()` only has "already installed" checks for dpkg (`dpkg -s umr`) and pacman
(`pacman -Qi umr`). There is no rpm check, so on Fedora/Bazzite it always falls through to
the install branch.

### Environment
- Bazzite 44.20260929 (rpm-ostree), kernel 7.2.7-ogc1.1.fc44, BC-250
- `bc250-cu-live-manager.sh` at `a929085`

### Suggested fix
Add an rpm check next to the other two, and treat "already requested" (staged but not yet
booted) as success:

```bash
	if command -v rpm >/dev/null 2>&1 && rpm -q umr >/dev/null 2>&1; then
		info "umr is already installed."
		return 0
	fi
```

and in the rpm-ostree branch, before failing:

```bash
		if rpm-ostree status --json 2>/dev/null | grep -q '"umr"'; then
			info "umr is already layered; reboot to activate it if you just added it."
			return 0
		fi
```

Thanks for the tool. Everything else in the persistence/revert flow re-tested cleanly on this
version (boot apply incl. a DRI instance flip 1 → 0, uninstall → reboot → 24 CU → reinstall).
