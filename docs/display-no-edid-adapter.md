# Display stuck at 640x480 / black after reboot (DP→HDMI adapter, no EDID) — tested

The BC-250 only has DisplayPort outputs, so most setups go through a **DP→HDMI adapter**. Some
adapters don't pass the sink's EDID (the monitor's or capture card's identification). The driver
then has no mode list and falls back to **640x480**: the desktop and the login screen run at
640x480 and get upscaled by the screen. On our board the same adapter also sometimes came up
**black after a warm reboot** until it was unplugged and replugged.

> ← Back to the [hub README](../README.md). This affects any setup, but it hits the
> [8-core unlock](cpu-8core-unlock-bazzite.md) harder, because that needs warm reboots.

## Diagnose

```bash
C=/sys/class/drm/card0-DP-1                 # your connector; see ls /sys/class/drm
cat $C/status; wc -c < $C/edid; cat $C/modes
#   connected / 0 / 640x480            <- no EDID, fallback mode only
sudo dmesg | grep -i edid
#   [drm:dm_helpers_read_local_edid [amdgpu]] *ERROR* EDID err: 2, on connector: DP-1
#   amdgpu 0000:01:00.0: [drm] *ERROR* No EDID read.
```

Forcing a re-probe (`echo detect | sudo tee $C/status`, even `off` → `detect`) did not make
the adapter answer on our board. The EDID really isn't coming through.

## Fix: tell the kernel the mode (system-wide)

A `video=` kernel argument adds a mode to the connector even without EDID. It applies to
everything: boot, login screen, desktop, Game Mode.

```bash
sudo rpm-ostree kargs --append-if-missing="video=DP-1:1920x1080@60"   # use your connector/mode
sudo systemctl reboot
cat /sys/class/drm/card0-DP-1/modes     # 1920x1080 now listed first (640x480 stays as fallback)
```

KWin remembers the last mode per output, and an EDID-less output always looks the same to it. So
if the desktop or the login screen were already saved at 640x480, switch them once:

```bash
kscreen-doctor -o                                   # find the 1920x1080 mode number, e.g. 1
kscreen-doctor output.DP-1.mode.1                   # your desktop session

# Plasma login screen (runs as its own user); this also saves its config:
U=$(id -u plasmalogin)
sudo -u plasmalogin env XDG_RUNTIME_DIR=/run/user/$U WAYLAND_DISPLAY=wayland-0 \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$U/bus kscreen-doctor output.DP-1.mode.1
```

Desktop-only alternative without touching the kernel command line: KWin 6.7 can add a custom
mode, e.g. `kscreen-doctor output.DP-1.addCustomMode.1920.1080.60000.full` and then select it.
It doesn't cover the login screen or Game Mode.

Revert: `sudo rpm-ostree kargs --delete="video=DP-1:1920x1080@60"` and reboot.

## Tested (Oct 2026, BC-250 → active DP→HDMI adapter → USB capture card)

- Before: EDID 0 bytes, only `640x480`, desktop and login screen at 640x480. One warm reboot
  came up black; unplugging/replugging the adapter brought the picture back.
- After `video=DP-1:1920x1080@60` and switching the saved modes: login screen and desktop at
  1920x1080. Verified frame by frame through the capture card on **4 warm reboots and 1 cold
  boot (Wake-on-LAN), all with picture**.
- We can't prove the `video=` argument is what stopped the black warm reboots; the failure may be
  intermittent. If it comes back, replug the adapter, and consider a different (e.g. passive)
  adapter. The [community display guide](https://elektricm.github.io/amd-bc250-docs/troubleshooting/display/)
  lists "works on first boot, fails after reboot" under adapter problems.
