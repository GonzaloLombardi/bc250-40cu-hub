# Kernel-patch method (mutable distros) — quick reference

If you're on a **traditional, mutable distro** (Arch, CachyOS, plain Fedora, Debian/Ubuntu —
anything with a writable `/usr/lib/modules` and normal kernel packages), the cleanest unlock
is the **kernel patch** from [`duggasco/bc250-40cu-unlock`](https://github.com/duggasco/bc250-40cu-unlock):
it writes the unlock registers at driver init, so `active_cu_number` actually becomes 40.

> On **Bazzite / Fedora Atomic / any immutable image**, do **not** use this — the module
> install fights the read-only OS. Use the [runtime-UMR guide](bazzite-40cu-runtime-umr.md)
> instead. This page is only for mutable systems.

> ⚠️ **The upstream repo is archived (17 September 2026).** It still clones and the patch,
> scripts and reports are all there, but it's read-only: if a future kernel breaks the patch
> or the build scripts, nobody will fix it there. Known open breakages at archive time include
> the Debian 13 / kernel 6.12 build
> ([#19](https://github.com/duggasco/bc250-40cu-unlock/issues/19)) and Debian source detection
> ([#7](https://github.com/duggasco/bc250-40cu-unlock/issues/7)). Check the issue tracker and
> the forks before you rely on it. The runtime-UMR route works on mutable distros too
> (WinnieLV's script supports apt, pacman/paru and dnf) and doesn't depend on this repo.

---

## When to choose this over runtime-UMR

| | Kernel patch | Runtime UMR |
|---|---|---|
| `active_cu_number` reports 40 | ✅ yes | ❌ stays 24 (SPI-routed) |
| Works on immutable distros | ❌ | ✅ |
| Survives kernel updates | ❌ rebuild per kernel | ✅ |
| Applied at | driver init | post-boot (systemd) |

| Upstream maintained | ❌ archived Sept 2026 | ✅ active |

On mutable distros either works. The kernel patch is the "cleaner" integration; runtime-UMR
is the lower-maintenance one, and since the archive it's also the only one still maintained.

---

## Method A — build script (any mutable distro)

```bash
git clone https://github.com/duggasco/bc250-40cu-unlock.git
cd bc250-40cu-unlock
sudo ./scripts/bc250-enable-40cu.sh build     # patch + compile amdgpu, backs up original
sudo ./scripts/bc250-enable-40cu.sh enable    # writes modprobe cfg, reboots
# Distro-specific variants for kernel 7.x:
#   sudo ./scripts/bc250-enable-40cu-fedora.sh build && ... enable   # Fedora (non-atomic, F44)
#   sudo ./scripts/bc250-enable-40cu-arch.sh   build && ... enable   # Arch
```

Requires `gcc`, `make`, `zstd`, `curl`, and matching `kernel-headers`/`kernel-devel`.

Subcommands: `build` · `enable` · `disable` · `restore` · `status`. The original module is
backed up to `…/amdgpu.ko.*.bc250-backup-*`; `restore` puts it back.

## Method B — manual patch

```bash
cd /path/to/linux-source/drivers/gpu/drm/amd/amdgpu/
patch -p5 < /path/to/bc250-40cu-unlock/patch/bc250-40cu-amdgpu.patch
make -C /lib/modules/$(uname -r)/build M=$(pwd) -j$(nproc) modules
sudo cp amdgpu.ko.zst /lib/modules/$(uname -r)/kernel/drivers/gpu/drm/amd/amdgpu/
sudo depmod -a
echo 'options amdgpu bc250_cc_write_mode=3' | sudo tee /etc/modprobe.d/bc250-40cu.conf
sudo reboot
```

## Method C — Arch / CachyOS PKGBUILD

Add `patch/bc250-40cu-amdgpu.patch` to your kernel PKGBUILD's patch array, rebuild the kernel
package, then add the `modprobe.d` option from Method B. (The patch was submitted upstream as
[CachyOS/kernel-patches#159](https://github.com/CachyOS/kernel-patches/pull/159). It's still
open and unmerged, with no activity since May 2026, and with the source repo archived it's
unlikely to move.)

---

## Activation flag & verification

The patch is **off by default** and device-gated (`0x13FE`). It only acts with:

```bash
options amdgpu bc250_cc_write_mode=3      # in /etc/modprobe.d/bc250-40cu.conf
```

Verify after reboot:

```bash
cat /sys/module/amdgpu/parameters/bc250_cc_write_mode   # 3
sudo dmesg | grep active_cu_number                      # active_cu_number 40
RADV_DEBUG=info vulkaninfo --summary 2>&1 | grep num_cu  # 40
```

## Selective masking (kernel-patch path)

```bash
options amdgpu bc250_cc_write_mode=3 disable_cu=1.0.3            # disable SE1.SH0 WGP3
options amdgpu bc250_cc_write_mode=3 disable_cu=0.0.4,0.1.4,1.0.4,1.1.4
```

duggasco also ships `bc250-cu-health-test.sh` + `bc250-cu-mask.sh` to auto-detect and mask
faulty WGPs. For the runtime equivalent, see
[selective WGP masking](selective-wgp-masking.md).

## Revert

```bash
sudo ./scripts/bc250-enable-40cu.sh disable    # remove modprobe cfg, reboot to 24 CU
sudo ./scripts/bc250-enable-40cu.sh restore    # restore original amdgpu module
```

---

*All credit for the patch, scripts, and register research:
[duggasco/bc250-40cu-unlock](https://github.com/duggasco/bc250-40cu-unlock). This page is a
summary/cross-link, not a replacement. The repo is archived, so for fixes on newer kernels
check its open issues/PRs and the [community docs](https://elektricm.github.io/amd-bc250-docs/).*
