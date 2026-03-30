# eGPU Switcher for SteamOS

Zero-config eGPU manager for SteamOS. Automatically detects your eGPU at every boot and sets it as the primary GPU using `boot_vga` bind mounts. No configuration needed — just install and go.

Works with any eGPU dock (USB4, Thunderbolt, OCuLink) on any SteamOS device. Tested on the Lenovo Legion Go S.

## How it works

On every boot, a systemd service scans for connected eGPUs. If one is found, it bind-mounts `boot_vga=1` onto the eGPU and `boot_vga=0` onto the iGPU before the display manager starts. This tells SteamOS to treat the eGPU as the primary GPU.

If the dock is disconnected, it safely does nothing — you boot normally on the internal GPU.

On shutdown, the bind mounts are cleaned up automatically.

## Install

Open Konsole (the terminal app in desktop mode) and paste this:

```bash
curl -sL https://github.com/YOUR_USERNAME/egpu-switcher/raw/main/egpu-switcher.sh -o ~/Desktop/egpu-switcher.sh && chmod +x ~/Desktop/egpu-switcher.sh && bash ~/Desktop/egpu-switcher.sh
```

This downloads the script, makes it runnable, and launches the installer GUI — all in one step. Follow the prompts, then reboot with your eGPU dock connected.

That's it. From now on, the eGPU is used automatically whenever the dock is connected. The script stays on your desktop — double-click it any time to check status, switch GPUs, or uninstall.

## Usage

**GUI** — Double-click the script (or run `egpu-switcher.sh gui`) to open the menu, where you can view status, switch GPUs live, reinstall, view logs, or uninstall.

**Terminal:**

```bash
egpu-switcher.sh status      # Show GPU and service status
egpu-switcher.sh install     # Install the boot service
egpu-switcher.sh uninstall   # Remove the boot service
egpu-switcher.sh --version   # Show version
egpu-switcher.sh --help      # Show help
```

## What gets installed

- `~/bin/egpu-switcher.sh` — the script itself
- `egpu-switcher-boot.service` — runs before display-manager on every boot
- `egpu-switcher-shutdown.service` — cleans up bind mounts on shutdown/reboot
- `~/.config/egpu-switcher/` — log file and bind mount records

All of this is removed cleanly by the uninstall option.

## SteamOS update safe

The script lives in your home directory (`~/bin/`), which SteamOS preserves across updates. The systemd units are in `/etc/systemd/system/` which may be wiped by a major SteamOS update — if that happens, just double-click the script again to reinstall.

## Migrating from other tools

If you previously used **all-ways-egpu** or **egpu-manager**, the installer automatically disables and removes their services. No manual cleanup needed.

## Troubleshooting

**eGPU not detected after boot:** Check the log with `egpu-switcher.sh status` or via the GUI. The service waits up to 15 seconds for the eGPU to appear — some docks take longer to initialize. If yours does, you can increase `MAX_RETRY` or `BOOT_DELAY` at the top of the script.

**Password prompt during install:** The script uses `pkexec` to install systemd services, which requires your user password. On a stock SteamOS install, the default password is usually empty or `deck`.

**GUI doesn't appear:** Make sure you're in desktop mode (not game mode). The GUI uses `kdialog`, which ships with KDE on SteamOS.

## License

MIT
