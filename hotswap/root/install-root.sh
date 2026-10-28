#!/bin/bash
# egpu-switcher: installs the root helper. Run with sudo.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run this with sudo" >&2; exit 1; }
src=$(dirname "$(readlink -f "$0")")

install -d -m 755 /etc/egpu-switcher
install -m 755 "$src/helper" /etc/egpu-switcher/helper
install -m 644 "$src/egpu-switcher-helper.service" /etc/systemd/system/egpu-switcher-helper.service
install -m 644 "$src/atomic-update-keep.conf" /etc/atomic-update.conf.d/egpu-switcher.conf

# v2 picked the GPU once per boot by swapping boot_vga, waiting up to 15 s for an eGPU first. The session
# wrapper now picks it on every Game Mode start. Its files stay; "systemctl enable" brings it back.
for unit in egpu-switcher-boot.service egpu-switcher-shutdown.service; do
    if [ -f "/etc/systemd/system/$unit" ]; then
        systemctl disable "$unit"
    fi
done

systemctl daemon-reload
systemctl enable egpu-switcher-helper.service
# restart, not start, so a reinstall runs the new helper
systemctl restart egpu-switcher-helper.service
echo "egpu-switcher-helper: $(systemctl is-active egpu-switcher-helper.service)"
