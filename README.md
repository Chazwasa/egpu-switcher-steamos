# eGPU Switcher for SteamOS

Hot-swap an eGPU in SteamOS Game Mode. Plug the eGPU in and Game Mode moves to its monitor. Tap **Volume Up, Down,
Up, Down** to eject it, pull the cable, and Game Mode is back on the handheld's screen. No restart, no Desktop Mode.

Tested on a Lenovo Legion Go S with an AOOSTAR EG02 and a Radeon RX 9070 XT over USB4. Game Mode only for now.

**Always eject before pulling the cable.** Pulling it while the eGPU is in use hits an AMD driver bug that needs a
restart to clear; the joystick lights tell you when that happened and how to restart.

How to use it, what the lights mean, how it works and how to remove it: [hotswap/README.md](hotswap/README.md).

## Install

SteamOS has no password by default. If you have never set one, open Konsole in Desktop Mode and run `passwd` first.

Then paste this into Konsole:

```bash
cd /tmp && rm -rf egpu-switcher-steamos-main && curl -sL https://github.com/Chazwasa/egpu-switcher-steamos/archive/refs/heads/main.tar.gz | tar xz && bash egpu-switcher-steamos-main/hotswap/install.sh
```

It asks for your password once, for the part that runs as root, then return to Game Mode. If you have the boot-time
switcher below installed, the installer turns its services off.

## Previous version: boot-time switcher (v2)

**No longer maintained.** The hot-swap above replaces it and gets the fixes from now on. v2 still works as before.

`egpu-switcher.sh` picks the GPU once per boot instead: it detects the eGPU at boot and sets it as the primary GPU
using `boot_vga` bind mounts. Switching needs a restart.

### How it works

On every boot, a systemd service scans for connected eGPUs. If one is found, it bind-mounts `boot_vga=1` onto the eGPU and `boot_vga=0` onto the iGPU before the display manager starts. This tells SteamOS to treat the eGPU as the primary GPU.

If the dock is disconnected, it safely does nothing — you boot normally on the internal GPU.

On shutdown, the bind mounts are cleaned up automatically.

### Install

Open Konsole (the terminal app in desktop mode) and paste this:

```bash
curl -sL https://github.com/Chazwasa/egpu-switcher-steamos/raw/main/egpu-switcher.sh -o ~/Desktop/egpu-switcher.sh && chmod +x ~/Desktop/egpu-switcher.sh && bash ~/Desktop/egpu-switcher.sh
```

This downloads the script, makes it runnable, and launches the installer GUI — all in one step. Follow the prompts, then reboot with your eGPU dock connected.

That's it. From now on, the eGPU is used automatically whenever the dock is connected. The script stays on your desktop — double-click it any time to check status, switch GPUs, or uninstall.

### Usage

**GUI** — Double-click the script (or run `egpu-switcher.sh gui`) to open the menu, where you can view status, switch GPUs live, reinstall, view logs, or uninstall.

**Terminal:**

```bash
egpu-switcher.sh status      # Show GPU and service status
egpu-switcher.sh install     # Install the boot service
egpu-switcher.sh uninstall   # Remove the boot service
egpu-switcher.sh --version   # Show version
egpu-switcher.sh --help      # Show help
```

### What gets installed

- `~/bin/egpu-switcher.sh` — the script itself
- `egpu-switcher-boot.service` — runs before display-manager on every boot
- `egpu-switcher-shutdown.service` — cleans up bind mounts on shutdown/reboot
- `~/.config/egpu-switcher/` — log file and bind mount records

All of this is removed cleanly by the uninstall option.

### SteamOS update safe

The script lives in your home directory (`~/bin/`), which SteamOS preserves across updates. The systemd units are in `/etc/systemd/system/`, whose `*.service` files SteamOS updates also keep.

### Migrating from other tools

If you previously used **all-ways-egpu** or **egpu-manager**, the installer automatically disables and removes their services. No manual cleanup needed.

### Troubleshooting

**eGPU not detected after boot:** Check the log with `egpu-switcher.sh status` or via the GUI.

- If the log says a Thunderbolt/USB4 device is connected but not authorized, run the `boltctl enroll` command it prints, once, with the dock connected. Where the Thunderbolt security level is `user`, boltd only authorizes a dock by itself if it is enrolled with policy `auto`; until then the eGPU does not appear. `boltctl list` shows each dock and its policy.
- The service waits up to 15 seconds for the eGPU to appear — some docks take longer to initialize. If yours does, increase `MAX_RETRY` or `BOOT_DELAY` at the top of `~/bin/egpu-switcher.sh`, the copy that runs at boot. Running the installer again replaces it with the copy you run it from.

**Password prompt during install:** The script uses `pkexec` to install systemd services, which requires your user password. On a stock SteamOS install, the default password is usually empty or `deck`.

**GUI doesn't appear:** Make sure you're in desktop mode (not game mode). The GUI uses `kdialog`, which ships with KDE on SteamOS.

## License

MIT
