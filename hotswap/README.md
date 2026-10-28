# eGPU hot-swap for SteamOS Game Mode (work in progress)

Plug the eGPU in and Game Mode moves to its monitor. Undock with a button pattern, pull the cable, and Game Mode is
back on the handheld's screen. No restart of the handheld, no Desktop Mode, nothing to click.

Tested on a Lenovo Legion Go S (83N6, Ryzen Z1 Extreme) with SteamOS 3.10 (kernel 7.2.7-valve2) and an AOOSTAR EG02
with a Radeon RX 9070 XT over USB4. It does not touch Desktop Mode yet.

## Using it

| You do | What happens |
|---|---|
| Plug in the eGPU (its monitor connected) | Game Mode restarts on the eGPU and its monitor, in about 15–20 seconds. The handheld's screen turns off. |
| Plug in the eGPU while a game runs | The game keeps running on the handheld. Game Mode moves to the monitor when you close the game. |
| Unplug or plug the monitor cable on the eGPU | Game Mode follows: to the handheld's screen, or back to the monitor. |
| Boot with the eGPU connected | Game Mode starts straight on the monitor. |
| Sleep while docked | Works; Game Mode is still on the monitor after waking. |

**Undocking: eject first.** Tap **Volume Up, Down, Up, Down** within 2 seconds. Game Mode moves to the handheld's
screen and the eGPU is taken off the PCI bus. The joystick lights say when you can pull the cable:

| Joystick lights | Meaning |
|---|---|
| Amber, breathing | Ejecting. Do not unplug. |
| Flashing amber and red | A game is running. Tap the pattern again within 10 seconds to eject and close it; otherwise nothing happens. |
| Green, 15 seconds | Safe to unplug. |
| Red, 15 seconds | The eject failed, or there is no eGPU. Do not unplug. |
| Flashing red, 30 seconds | The eGPU was pulled without an eject: restart needed (see below). |

There is a sound for each as well, when the volume is up. To use an ejected eGPU again, unplug and replug it, or run
`~/.local/lib/egpu-switcher/eject --attach`.

## Do not pull the cable without ejecting

Pulling the eGPU while Game Mode uses it hits a bug in AMD's driver (amdgpu, on this kernel): the driver waits for GPU
work that can never finish, and part of the kernel stays stuck. Game Mode comes back on the handheld after 10 seconds
to a minute, but the eGPU cannot be used again until a restart, and a normal restart hangs on the stuck GPU. Reported
to Valve as [ValveSoftware/SteamOS#3002](https://github.com/ValveSoftware/SteamOS/issues/3002).

If it happens anyway, the joystick lights **flash red** about 20 seconds after the pull (and again if you plug the dock
back in). Tap the pattern, then tap it again while the lights flash amber and red: the lights go solid red, and the
handheld writes everything to disk and restarts at once, skipping the step a normal restart hangs on.

Putting the handheld to sleep and pulling the cable while it sleeps is worse: it hangs on waking, and only holding the
power button gets out of it.

The eject avoids all of this by making sure nothing uses the GPU when it is removed.

## How it works

gamescope picks its GPU when it starts and cannot change it while it runs, so every move between the two GPUs is a
restart of Game Mode.

| Part | Installed as | What it does |
|---|---|---|
| `user/gamescope-session` | `~/.local/lib/egpu-switcher/` | Wraps Valve's Game Mode session (through `user/systemd/50-egpu-switcher.conf`, a drop-in for `gamescope-session.service`). If an eGPU with a connected monitor is present, it points gamescope, Steam and games at it; otherwise Valve's session starts unchanged. |
| `user/shim/gamescope` | `~/.local/lib/egpu-switcher/shim/` | Adds `--prefer-vk-device` to Valve's gamescope command. |
| `user/watch` | `~/.local/lib/egpu-switcher/`, run by `egpu-switcher-watch.service` | Watches for monitors and GPUs being plugged in or out, and restarts Game Mode when it should move. |
| `user/eject` | `~/.local/lib/egpu-switcher/` | The eject: moves Game Mode and sound off the eGPU, then asks the root helper to remove it. |
| `user/buttons` | `~/.local/lib/egpu-switcher/`, run by `egpu-switcher-buttons.service` | Listens for the volume pattern, drives the joystick lights, and notices when the eGPU's port reports no card while the eGPU is still on the bus (the stuck state). |
| `root/helper` | `/etc/egpu-switcher/`, run by `egpu-switcher-helper.service` | The only part that runs as root. It turns the handheld's screen off while Game Mode is on the eGPU, does the eject's root steps, and the quick restart (SysRq sync, read-only, reboot), which it refuses unless the eGPU is stuck. It takes requests from a pipe only the `deck` group can write. |

Everything outside `/etc` lives in your home folder. SteamOS updates keep `/etc/systemd/system/*.service`, and
`root/atomic-update-keep.conf` adds `/etc/egpu-switcher/` to what they keep.

The installer turns off the services of the boot-time switcher (`egpu-switcher.sh`, v2) if they are installed: this
replaces them. Their files are left in place.

## Install

From a copy of this repository on the handheld:

```bash
./hotswap/install.sh
```

It asks for your password once, for the root helper. Game Mode uses the eGPU from its next start.

## Remove

```bash
systemctl --user disable --now egpu-switcher-watch.service egpu-switcher-buttons.service
rm -r ~/.local/lib/egpu-switcher ~/.config/systemd/user/egpu-switcher-*.service ~/.config/systemd/user/gamescope-session.service.d/50-egpu-switcher.conf
systemctl --user daemon-reload
sudo systemctl disable --now egpu-switcher-helper.service
sudo rm -r /etc/egpu-switcher /etc/systemd/system/egpu-switcher-helper.service /etc/atomic-update.conf.d/egpu-switcher.conf
```

## Not done yet

- Desktop Mode
- The PCIe link between the dock and the GPU idles at 2.5 GT/s under light load
