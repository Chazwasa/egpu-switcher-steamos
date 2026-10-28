#!/bin/bash
# egpu-switcher hot-swap installer. Installs the user parts into your home folder, then the root helper with sudo
# (it asks for your password). Run it again to update.
set -euo pipefail
src=$(dirname "$(readlink -f "$0")")
lib="$HOME/.local/lib/egpu-switcher"
units="$HOME/.config/systemd/user"

install -d "$lib/shim" "$units/gamescope-session.service.d"
install -m 755 "$src/user/gamescope-session" "$src/user/watch" "$src/user/eject" "$src/user/buttons" "$lib/"
install -m 755 "$src/user/shim/gamescope" "$lib/shim/"
install -m 644 "$src/user/systemd/50-egpu-switcher.conf" "$units/gamescope-session.service.d/"
install -m 644 "$src/user/systemd/egpu-switcher-watch.service" "$src/user/systemd/egpu-switcher-buttons.service" "$units/"
systemctl --user daemon-reload
systemctl --user enable egpu-switcher-watch.service egpu-switcher-buttons.service
# restart, not start, so an update runs the new versions
systemctl --user restart egpu-switcher-watch.service egpu-switcher-buttons.service

sudo bash "$src/root/install-root.sh"

echo "Installed. Game Mode uses the new session wrapper from its next start: restart, or go to Desktop Mode and back."
