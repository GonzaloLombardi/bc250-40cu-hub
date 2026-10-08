# BC-250 on Omarchy (Arch + Hyprland): every tweak, tested

This page is the Omarchy version of the Bazzite guides in this repo. We wiped our test board,
installed **Omarchy 4.0.4** (Arch, `linux-omarchy` 7.2.5, Mesa 26.2.2, Hyprland, Limine) and
re-applied everything: 40 CU, GPU governor, CPU ACPI fix, 8-core unlock with its cold-boot
service, and the display fix. Then we re-ran the Bazzite benchmarks on the same board (Oct 2026).

**Short version: everything works, and GPU performance is identical to Bazzite (within 0.4 %).**
Most steps are simpler than on Bazzite (no rpm-ostree, no reboot to layer a package). What changes
is *where* things go: mkinitcpio instead of dracut, `limine-entry-tool` instead of kernel args,
Hyprland's Lua config instead of KDE.

> ← Back to the [hub README](../README.md). The *why* behind each tweak is in the Bazzite pages
> linked from each section; this page only covers what's different on Omarchy, plus the results.
> Any Arch-based distro with mkinitcpio should work the same way; the Limine and Hyprland bits are
> Omarchy-specific.

---

## At a glance

| Tweak | Bazzite | Omarchy | Result on Omarchy |
|---|---|---|---|
| [GPU governor](governor-tuning.md) | `rpm-ostree install` | `yay -S cyan-skillfish-governor-smu` | ✅ same v0.4.14, same config |
| [40 CU](bazzite-40cu-runtime-umr.md) | layer `umr` + reboot | `yay -S umr`, no reboot | ✅ 40/40, **1.56×** |
| [CPU ACPI fix](cpu-acpi-fix-bazzite.md) | dracut + `rpm-ostree initramfs` | mkinitcpio `acpi_override` hook + `limine-update` | ✅ `acpi-cpufreq`, C1–C3 |
| [8-core unlock](cpu-8core-unlock-bazzite.md) + re-apply service | same script, same units | same script, same units | ✅ 16 threads, cold boot tested |
| Reboot notice | KDE notification with buttons | click-to-reboot notification (no buttons, see below) | ✅ tested |
| [Display fix](display-no-edid-adapter.md) | `rpm-ostree kargs` + `kscreen-doctor` | `limine-entry-tool.d` + `monitors.lua` | ✅ 1080p without EDID |
| Wake-on-LAN | `nmcli` | `nmcli` (Omarchy uses NetworkManager) | ✅ woke from power-off |

## Omarchy things to know first

- **Snapshots are your rollback.** Omarchy ships btrfs + snapper, and Limine lists snapshots in
  its boot menu. Take one before you start: `sudo snapper -c root create -d "before BC-250 tweaks"`.
- **`sudo` asks for a password.** Every command below that writes the system needs it.
- **Hyprland's config is Lua** (`~/.config/hypr/*.lua`). There's no `monitors.conf` or
  `input.conf`, and `hyprctl dispatch` takes Lua: `hyprctl dispatch 'hl.dsp.dpms({ action = "enable" })'`.
- **The kernel command line is built by `limine-entry-tool`** into a unified kernel image (UKI).
  Add arguments as a drop-in in `/etc/limine-entry-tool.d/`, then run `sudo limine-update`.
  Editing `/etc/default/limine` alone does nothing useful.
- **mkinitcpio drop-ins load in name order, and Omarchy's `omarchy_hooks.conf` assigns
  `HOOKS=(...)` from scratch.** A drop-in that appends a hook has to sort after it (name it `zz-…`).
- **The AUR helper is `yay`**, not `paru`.
- **No autologin.** The board boots to the SDDM login screen, so login-time notices appear only
  after you sign in.
- **SSH is off by default.** Turn it on with `sudo systemctl enable --now sshd`, or let the
  installer do it (see the unattended install below).

---

## Optional: unattended install from a single USB stick

Omarchy's ISO [installs itself](https://omarchy.org/manual/unattended-installs/) if it finds a
drive labeled `cidata` holding the wizard's answer files. We used it to reinstall the board with
nobody at the keyboard, and **with SSH already set up**, which matters on a headless BC-250.
Things the manual doesn't tell you:

- **The JSON format isn't documented.** The files are what the wizard writes. We built them from
  the installer's own template ([`configs/airootfs/root/configurator`](https://github.com/omacom/omarchy-iso/blob/main/configs/airootfs/root/configurator)
  in `omacom/omarchy-iso`). Use the version matching your ISO's build date: newer revisions add
  keys an older ISO doesn't know.
- **Partition sizes are absolute bytes**, computed from the target disk's size, so the config only
  fits the disk it was made for. Use the stable device path (`/dev/nvme0n1` on the BC-250, not a
  `/dev/sdX` that a USB stick could take).
- **`authorized_keys` on the drive** makes the installer enable `sshd` and open the firewall.
  Without it, a stock install has SSH off.
- **Generate the password hash** with `openssl passwd -6 -stdin`; the user and root get the same
  hash, like the wizard does. With encryption on, the LUKS passphrase sits **in plain text** in
  the config, and you'll still need a keyboard at every boot. We installed without it.
- **You don't need a second stick.** The ISO written to a USB stick leaves free space after it. A
  small FAT32 partition labeled `CIDATA` appended there works:

  ```bash
  # On a Linux box, stick = /dev/sdX. The ISO ends before the new partition starts.
  sudo sfdisk -d /dev/sdX                                    # note where the last partition ends
  echo "start=<aligned sector after it>, size=131072, type=c" | sudo sfdisk --append --wipe never /dev/sdX
  sudo mkfs.vfat -F 32 -n CIDATA /dev/sdX3                  # then copy the files onto it
  ```

  The ISO data stays intact (we hashed it before and after); only the partition table in the
  first sector changes, so the stick no longer matches the ISO's checksum as a whole.
- **Boot it once from the one-time boot menu, and unplug it when the install reboots.** With
  the answers on the boot stick itself, booting from it again starts a second install that
  wipes the disk again.

---

## Display: force 1080p without EDID

Same root cause as on Bazzite: our DP→HDMI adapter loses the EDID now and then, and DP-1 falls
back to 640x480 (the capture card then shows color bars). On the fresh install the EDID read
fine at first and was lost a few minutes later, so don't assume you're unaffected. Background
in the [display page](display-no-edid-adapter.md).

```bash
# Kernel: covers boot, the LUKS prompt and the SDDM login screen
printf '%s\n' 'KERNEL_CMDLINE[default]+=" video=DP-1:1920x1080@60"' \
  | sudo tee /etc/limine-entry-tool.d/bc250-video.conf
sudo limine-update
```

```lua
-- ~/.config/hypr/monitors.lua (append): Hyprland reloads it on save
hl.monitor({ output = "DP-1", mode = "1920x1080@60", position = "0x0", scale = 1 })
```

Hyprland applies the mode even though the connector only lists 640x480. Check with
`hyprctl monitors`.

> If the capture card shows color bars, check that the display isn't simply **asleep**:
> `hyprctl monitors` → `dpmsStatus: 0`. Omarchy turns the screen off when idle; wake it with
> `hyprctl dispatch 'hl.dsp.dpms({ action = "enable" })'`.

## GPU governor

```bash
yay -S cyan-skillfish-governor-smu
sudo systemctl enable --now cyan-skillfish-governor-smu.service
```

The AUR package is maintained by the governor's author. It builds the tagged release from GitHub
(Rust, a few minutes) and has no install scripts. The shipped `config.toml` was byte-identical to
the one on Bazzite. **Do lower the floor to 500 MHz**: −10 W at idle with no throughput loss
([measured](governor-tuning.md#lowering-the-floor-to-500-mhz-10-w-less-at-idle)).

## 40 CU (runtime UMR)

```bash
yay -S umr        # 1.0.11, the same version Bazzite ships; official freedesktop source
curl -fL -o ~/bc250-cu-live-manager.sh \
  https://raw.githubusercontent.com/WinnieLV/bc250-cu-live-manager/refs/heads/main/bc250-cu-live-manager.sh
chmod +x ~/bc250-cu-live-manager.sh
sudo ~/bc250-cu-live-manager.sh status
sudo ~/bc250-cu-live-manager.sh enable all --dry-run
sudo ~/bc250-cu-live-manager.sh enable all --yes
sudo ~/bc250-cu-live-manager.sh write-service-table --yes
sudo ~/bc250-cu-live-manager.sh install-service --yes
```

Same commands as the [Bazzite guide](bazzite-40cu-runtime-umr.md), minus the reboot: there's
nothing to layer. Notes:

- **Use `yay` for `umr`, not the script's `install-umr`.** It knows pacman and `paru` but not
  `yay`, and `umr` isn't in the official repos, so on stock Omarchy it can't install it.
- **`umr` links against `libLLVM`.** When Arch moves to a new LLVM major, rebuild it
  (`yay -S umr`) or the boot service will fail to run it.
- The harvest map, the dry-run plan and the service unit were identical to Bazzite's.

## CPU ACPI fix (P-states + C-states)

Use the **16-thread** tables if you'll do the 8-core unlock (we installed them straight away).
Both sets come from the repos linked in the [ACPI page](cpu-acpi-fix-bazzite.md).

```bash
sudo install -Dm644 -t /etc/initcpio/acpi_override SSDT-CST.aml SSDT-PST.aml
printf '%s\n' 'HOOKS+=(acpi_override)' | sudo tee /etc/mkinitcpio.conf.d/zz-bc250-acpi-override.conf
sudo limine-update          # rebuilds the UKI; the log shows "Running build hook: [acpi_override]"
```

`acpi_override` is a stock mkinitcpio hook that puts the tables in the early, uncompressed
initramfs, which ends up inside the UKI. The `zz-` prefix matters (see
[Omarchy things to know](#omarchy-things-to-know-first)). After a reboot:

```bash
sudo dmesg | grep -i "Table Upgrade"          # install [SSDT-  HACK-  P_CST3] and [... PSTATES]
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver    # acpi-cpufreq
```

## 8-core unlock, re-apply service and reboot notice

The unlock, the re-apply service, the `/run` marker drop-in and the terminal prompt are the
**same files as on Bazzite**. Copy them from the [8-core page](cpu-8core-unlock-bazzite.md#surviving-cold-boots-a-re-apply-service-that-never-reboots).
Our board read the standard `0x77` mask. Only the desktop notice needs changes.

**Omarchy's notification server (its quickshell) draws no action buttons.** It only runs the
action with the identifier `default`, when you click the notification body. The Bazzite script
registers `reboot` and `later`, so on Omarchy clicking it does nothing. This version works on
both desktops: a click on the body reboots on Omarchy, and Plasma still shows the two buttons.
The click instruction goes first because Omarchy cuts the body at three lines.

```bash
# /usr/local/bin/bc250-cpu-unlock-notify  (chmod 755)
#!/usr/bin/env bash
FLAG=/run/bc250/cpu-unlock-pending
[ -f "$FLAG" ] || exit 0
[ "$(nproc --all)" -ge 16 ] && exit 0
sleep 8   # give the notification server (Plasma / Omarchy quickshell) time to start
ans=$(notify-send --app-name="BC-250" --icon=system-reboot --urgency=critical \
  --action=default="Reiniciar ahora" \
  --action=reboot="Reiniciar ahora" --action=later="Más tarde" \
  "BC-250: 8 núcleos listos para activar" \
  "Hacé clic acá para reiniciar y activarlos (cerrala para hacerlo más tarde). Tras el apagado completo arrancó con $(nproc --all) hilos.")
case "$ans" in default|reboot) exec systemctl reboot ;; esac
exit 0
```

Hyprland doesn't run XDG autostart entries, so start it from the Lua autostart file:

```lua
-- ~/.config/hypr/autostart.lua (append)
o.launch_on_start("/usr/local/bin/bc250-cpu-unlock-notify")
```

> **Testing it over SSH won't reboot.** A notifier started from an SSH shell isn't in your seat
> session, so polkit refuses the passwordless `systemctl reboot` and the click silently does
> nothing. Start it inside Hyprland instead:
> `hyprctl dispatch "hl.dsp.exec_cmd([[/usr/local/bin/bc250-cpu-unlock-notify]])"`.
> Also, don't `pkill -f /usr/local/bin/bc250-…` through `ssh host '…'`: the pattern matches the
> remote shell's own command line and kills your session.

## Wake-on-LAN

Omarchy uses NetworkManager, so the [same `nmcli` setting](cpu-8core-unlock-bazzite.md#surviving-cold-boots-a-re-apply-service-that-never-reboots)
applies. A fresh install had it at `default` (off):

```bash
C=$(nmcli -g GENERAL.CONNECTION device show enp4s0)
sudo nmcli connection modify "$C" 802-3-ethernet.wake-on-lan magic && sudo nmcli device reapply enp4s0
```

`ethtool` isn't installed by default; with it, `sudo ethtool enp4s0 | grep Wake-on` should show `g`.

---

## Tested: warm reboot, then a full power cycle

After a warm reboot everything came back on its own: 40/40 CUs, 16 threads, `acpi-cpufreq` with
C1–C3, governor active, 1080p from the boot screen on, no failed units.

The cold-boot cycle, done remotely:

| Step | What happened |
|---|---|
| `systemctl poweroff`, then a magic packet from another machine | the board powered on |
| Boot | 12 threads; the service read `0x77`, wrote `0xff`, left the marker, no reboot |
| SSH login (interactive) | terminal prompt offered the reboot; *n* left it alone |
| Desktop login | notification appeared; a click rebooted the board |
| After that reboot | **16 threads**, marker gone, 40/40 CUs, governor active |

## Benchmarks: Omarchy vs Bazzite (same board, same scripts)

Same model (Qwen2.5-3B Q4_K_M), same llama.cpp builds and the repo's scripts. The Bazzite numbers
are from the October 2026 runs in the other pages.

**GPU: identical.**

| Test | Bazzite | Omarchy |
|---|---|---|
| 40 CU vs 24 CU, pp512 (`b11382`, [`benchmark-40cu.sh`](../scripts/benchmark-40cu.sh)) | 1076 / 685 → **1.56×** | 1074 / 690 → **1.56×** |
| Fixed 1500 / 1700 / 1850 / 2000 MHz, pp512 (`b9538`, [`sweep-clocks.sh`](../scripts/sweep-clocks.sh)) | 881 / 992 / 1068 / 1140 | 879 / 990 / 1064 / 1137 |
| Adaptive governor, pp512 (`b9538`) | 1071 | 1071 |
| Idle package power (floor 1000 MHz) | 42.5 W | 42.9 W |

(With the 8-core unlock active, the sweep's `sclk` column reads garbage, a known side effect; the
throughput and voltage columns are fine.)

**CPU: same clocks and power; the 7-Zip score isn't comparable.**

| 7-Zip `7z b`, 16 threads | Bazzite | Omarchy | Package power |
|---|---|---|---|
| No cap (boost) | 52,614 MIPS | 66,377 | 73 / 75 W |
| Cap 2550 MHz | 36,263 | 51,157 | 52 / 53 W |
| Cap 1960 MHz | 31,267 | 40,538 | 49 / 50 W |

Omarchy scores 26–41 % higher at the same clocks and the same power. That's the benchmark, not
the OS: Omarchy ships 7-Zip 26.03, and we didn't record which `7z` the Bazzite runs used (an old
p7zip would explain it). Use the ratios within each column, not across. `stress-ng --verify` on
all 16 threads passed 16/16.

**CPU + GPU together** (`stress-ng` on 16 threads + pp512): with the CPU capped at 2550 MHz,
1042 tok/s, CPU peak 83 °C, GPU peak 85 °C (Bazzite: 1048 tok/s, 79 / 82 °C). Without the cap,
the CPU hit the script's 95 °C watchdog (Bazzite peaked at 94 °C). Idle temperatures were also
3–4 °C higher than in the Bazzite runs, so we read this as a warmer room or weaker airflow, not
the OS. Either way, the 2550 MHz cap [recommended for combined loads](cpu-8core-unlock-bazzite.md#results-measured)
matters even more on this board now.

## Revert

- Everything at once: boot an older snapshot from the Limine menu, or `snapper rollback`.
- One piece at a time:
  - 40 CU: `sudo ~/bc250-cu-live-manager.sh uninstall-service`
  - 8-core service: `sudo systemctl disable bc250-cpu-unlock.service`, then a power-off for 6 cores
  - ACPI fix / `video=`: delete the drop-in (`/etc/mkinitcpio.conf.d/zz-bc250-acpi-override.conf`
    or `/etc/limine-entry-tool.d/bc250-video.conf`) and run `sudo limine-update`
  - Display mode: remove the `hl.monitor` line

*No warranty. These tweaks write GPU and SMU registers and raise power and heat. Keep a remote
shell and decent cooling, and read each tool's safety notes first.*
