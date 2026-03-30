#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# egpu-switcher.sh — Zero-config eGPU manager for SteamOS
#
# Auto-detects your eGPU at every boot and sets it as the primary GPU
# using boot_vga bind mounts. No configuration needed — just install and go.
#
# Works with any eGPU dock (USB4, Thunderbolt, OCuLink) on any SteamOS device.
# Survives SteamOS updates. Safe when the dock is disconnected.
#
# Usage:
#   Double-click this file    — Launch GUI (auto-installs if needed)
#   ./egpu-switcher.sh status — Show GPU status in terminal
#   ./egpu-switcher.sh gui    — Launch GUI manually
#
# After install, everything is automatic on every boot.
#

# set -e only for boot/cleanup (systemd paths). GUI must handle errors gracefully.
set -uo pipefail

VERSION="2.1.0"

# ─── Paths ───────────────────────────────────────────────────────────────────
# SteamOS always uses "deck", but this makes forks easier
USER_HOME="/home/deck"

CONFIG_DIR="${USER_HOME}/.config/egpu-switcher"
LOG_FILE="${CONFIG_DIR}/last-boot.log"
BIND_RECORD="${CONFIG_DIR}/bind-paths"
BIN_DIR="${USER_HOME}/bin"
BIN_SCRIPT="${BIN_DIR}/egpu-switcher.sh"
SYSTEMD_DIR="/etc/systemd/system"
SVC_BOOT="egpu-switcher-boot.service"
SVC_SHUTDOWN="egpu-switcher-shutdown.service"

# Boot parameters
MAX_RETRY=15
BOOT_DELAY=1

# GUI mode flag
GUI_MODE=0

# ─── GPU discovery arrays (populated by discover_gpus) ───────────────────────
GPU_BUS_IDS=()
GPU_BOOT_VGA=()
GPU_DRI_CARD=()
GPU_DRIVER=()
GPU_NAME=()
GPU_SYSFS_DEPTH=()
IGPU_IDX=-1
EGPU_IDX=-1

# ─── Logging ─────────────────────────────────────────────────────────────────
log() {
    echo "[$(date '+%F %T')] $*"
}

# ─── Colors (terminal only) ──────────────────────────────────────────────────
if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
fi

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERR ]${NC} $*"; }

# ─── GUI helpers (kdialog — ships with KDE on SteamOS) ───────────────────────
gui_msg()   { kdialog --title "eGPU Switcher" --msgbox "$1" 2>/dev/null; }
gui_error() { kdialog --title "eGPU Switcher" --error "$1" 2>/dev/null; }
gui_yesno() { kdialog --title "eGPU Switcher" --yesno "$1" 2>/dev/null; }
gui_popup() { kdialog --title "eGPU Switcher" --passivepopup "$1" 5 2>/dev/null || true; }
gui_text()  { local tmp; tmp=$(mktemp /tmp/egpu-status-XXXXX.txt); echo "$1" > "$tmp"; kdialog --title "eGPU Switcher" --textbox "$tmp" 700 500 2>/dev/null; rm -f "$tmp"; }

gui_menu() {
    local prompt="$1"; shift
    kdialog --title "eGPU Switcher v${VERSION}" --menu "$prompt" "$@" 2>/dev/null
}

# ─── GPU Discovery ───────────────────────────────────────────────────────────
# Scans sysfs for all GPUs. Identifies iGPU and eGPU dynamically.
# No stored config needed — works even when bus IDs change between boots.
discover_gpus() {
    GPU_BUS_IDS=()
    GPU_BOOT_VGA=()
    GPU_DRI_CARD=()
    GPU_DRIVER=()
    GPU_NAME=()
    GPU_SYSFS_DEPTH=()
    IGPU_IDX=-1
    EGPU_IDX=-1

    local dev bus_id class boot_vga dri_card driver name sysfs_depth

    for dev in /sys/bus/pci/devices/*; do
        [ -f "$dev/class" ] || continue
        class=$(<"$dev/class")

        # VGA (0x0300xx), 3D controller (0x0302xx), Display controller (0x0380xx)
        case "$class" in
            0x0300*|0x0302*|0x0380*) ;;
            *) continue ;;
        esac

        bus_id=$(basename "$dev")

        # Read boot_vga flag
        boot_vga="-1"
        [ -f "$dev/boot_vga" ] && boot_vga=$(<"$dev/boot_vga")

        # Find DRI card device
        dri_card=""
        for card_dir in "$dev"/drm/card*; do
            [ -d "$card_dir" ] || continue
            dri_card="/dev/dri/$(basename "$card_dir")"
            break
        done

        # Get kernel driver
        driver="none"
        [ -L "$dev/driver" ] && driver=$(basename "$(readlink "$dev/driver")")

        # Human-readable name (lspci may not be available at very early boot)
        name="Unknown GPU"
        if command -v lspci &>/dev/null; then
            name=$(lspci -s "$bus_id" 2>/dev/null | cut -d: -f3- | sed 's/^ //')
            [ -z "$name" ] && name="Unknown GPU"
        fi

        # Sysfs path depth — eGPUs are deeper (more bridges in the chain)
        sysfs_depth=$(readlink -f "$dev" | tr -cd '/' | wc -c)

        GPU_BUS_IDS+=("$bus_id")
        GPU_BOOT_VGA+=("$boot_vga")
        GPU_DRI_CARD+=("$dri_card")
        GPU_DRIVER+=("$driver")
        GPU_NAME+=("$name")
        GPU_SYSFS_DEPTH+=("$sysfs_depth")
    done

    local i

    # Identify iGPU: the GPU with boot_vga=1
    for i in "${!GPU_BUS_IDS[@]}"; do
        if [ "${GPU_BOOT_VGA[$i]}" = "1" ]; then
            IGPU_IDX=$i
            break
        fi
    done

    # Fallback: if no boot_vga=1 (bind mounts may already be applied), use shallowest sysfs path
    if [ "$IGPU_IDX" -eq -1 ] && [ "${#GPU_BUS_IDS[@]}" -gt 0 ]; then
        local min_depth=99999
        for i in "${!GPU_BUS_IDS[@]}"; do
            if [ "${GPU_SYSFS_DEPTH[$i]}" -lt "$min_depth" ]; then
                min_depth="${GPU_SYSFS_DEPTH[$i]}"
                IGPU_IDX=$i
            fi
        done
    fi

    # Identify eGPU: has DRI device, real driver, is not the iGPU
    for i in "${!GPU_BUS_IDS[@]}"; do
        [ "$i" -eq "$IGPU_IDX" ] && continue
        [ -z "${GPU_DRI_CARD[$i]}" ] && continue
        [ "${GPU_DRIVER[$i]}" = "none" ] && continue
        EGPU_IDX=$i
        break
    done
}

# ─── Status Text ─────────────────────────────────────────────────────────────
build_status() {
    discover_gpus

    local status_text=""
    local i

    status_text+="eGPU Switcher v${VERSION}\n"
    status_text+="══════════════════════════════════════════════\n\n"

    if [ "${#GPU_BUS_IDS[@]}" -eq 0 ]; then
        status_text+="No GPUs detected!\n"
        echo -e "$status_text"
        return
    fi

    for i in "${!GPU_BUS_IDS[@]}"; do
        local label="GPU"
        if [ "$i" -eq "$IGPU_IDX" ]; then
            label="iGPU (internal)"
        elif [ "$i" -eq "$EGPU_IDX" ]; then
            label="eGPU (external)"
        fi

        status_text+="${label}\n"
        status_text+="  ${GPU_NAME[$i]}\n"
        status_text+="  Bus: ${GPU_BUS_IDS[$i]}  |  boot_vga: ${GPU_BOOT_VGA[$i]}  |  Driver: ${GPU_DRIVER[$i]}\n"
        if [ -n "${GPU_DRI_CARD[$i]}" ]; then
            status_text+="  DRI: ${GPU_DRI_CARD[$i]}\n"
        else
            status_text+="  DRI: (no card device)\n"
        fi
        status_text+="  Sysfs depth: ${GPU_SYSFS_DEPTH[$i]}\n"
        status_text+="\n"
    done

    # Service status
    status_text+="──────────────────────────────────────────────\n"
    status_text+="Services:\n"
    if [ -f "${SYSTEMD_DIR}/${SVC_BOOT}" ]; then
        local enabled_state
        enabled_state=$(systemctl is-enabled "$SVC_BOOT" 2>/dev/null || echo "unknown")
        local active_state
        active_state=$(systemctl is-active "$SVC_BOOT" 2>/dev/null || echo "unknown")
        status_text+="  Boot service:     ${enabled_state} / last: ${active_state}\n"
    else
        status_text+="  Boot service:     NOT INSTALLED\n"
    fi
    if [ -f "${SYSTEMD_DIR}/${SVC_SHUTDOWN}" ]; then
        local s_enabled
        s_enabled=$(systemctl is-enabled "$SVC_SHUTDOWN" 2>/dev/null || echo "unknown")
        status_text+="  Shutdown service: ${s_enabled}\n"
    else
        status_text+="  Shutdown service: NOT INSTALLED\n"
    fi

    # Active bind mounts
    status_text+="\n"
    if [ -f "$BIND_RECORD" ] && [ -s "$BIND_RECORD" ]; then
        status_text+="Active bind mounts:\n"
        while read -r path val; do
            status_text+="  ${path} → ${val}\n"
        done < "$BIND_RECORD"
    else
        status_text+="No active bind mounts (boot_vga flags are at hardware defaults)\n"
    fi

    # Last boot log
    if [ -f "$LOG_FILE" ] && [ -s "$LOG_FILE" ]; then
        status_text+="\n──────────────────────────────────────────────\n"
        status_text+="Last boot log:\n"
        status_text+="$(tail -25 "$LOG_FILE" | sed 's/^/  /')\n"
    fi

    echo -e "$status_text"
}

# ─── Boot: swap boot_vga flags ──────────────────────────────────────────────
do_boot() {
    set -e  # strict mode for boot path — failures should be visible in journal

    # Prevent concurrent runs (e.g. manual + systemd race)
    local lockfile="/tmp/egpu-switcher.lock"
    exec 9>"$lockfile"
    if ! flock -n 9; then
        log "Another instance is already running, exiting."
        exit 0
    fi

    # Truncate log for this boot
    mkdir -p "$CONFIG_DIR"
    : > "$LOG_FILE"
    chown -R "$(basename "$USER_HOME"):$(basename "$USER_HOME")" "$CONFIG_DIR" 2>/dev/null || true

    log "=== eGPU Switcher v${VERSION} boot ==="

    # Clean up any stale bind mounts from a previous boot
    do_cleanup_quiet

    local retry=0
    while [ "$retry" -le "$MAX_RETRY" ]; do
        discover_gpus

        if [ "$EGPU_IDX" -ge 0 ]; then
            break
        fi

        retry=$((retry + 1))
        if [ "$retry" -le "$MAX_RETRY" ]; then
            log "No eGPU detected yet, retry ${retry}/${MAX_RETRY}..."
            sleep "$BOOT_DELAY"
        fi
    done

    if [ "$EGPU_IDX" -lt 0 ]; then
        log "No eGPU detected after ${MAX_RETRY} retries. Booting with iGPU only."
        log "This is normal if the eGPU dock is not connected."
        exit 0
    fi

    local egpu_bus="${GPU_BUS_IDS[$EGPU_IDX]}"
    local igpu_bus="${GPU_BUS_IDS[$IGPU_IDX]}"

    log "Found ${#GPU_BUS_IDS[@]} GPU(s)"
    log "  iGPU: ${igpu_bus} — ${GPU_NAME[$IGPU_IDX]} (boot_vga=${GPU_BOOT_VGA[$IGPU_IDX]})"
    log "  eGPU: ${egpu_bus} — ${GPU_NAME[$EGPU_IDX]} (boot_vga=${GPU_BOOT_VGA[$EGPU_IDX]})"

    # Create the flag files
    local flag_dir="/tmp/egpu-switcher"
    mkdir -p "$flag_dir"
    echo 1 > "${flag_dir}/1"
    echo 0 > "${flag_dir}/0"

    # Bind mount boot_vga=1 on eGPU
    local egpu_boot_vga="/sys/bus/pci/devices/${egpu_bus}/boot_vga"
    local igpu_boot_vga="/sys/bus/pci/devices/${igpu_bus}/boot_vga"

    : > "$BIND_RECORD"

    if [ -f "$egpu_boot_vga" ]; then
        mount -n --bind -o ro "${flag_dir}/1" "$egpu_boot_vga"
        echo "${egpu_boot_vga} 1" >> "$BIND_RECORD"
        log "Set boot_vga=1 on eGPU (${egpu_bus})"
    else
        log "WARNING: ${egpu_boot_vga} does not exist, skipping"
    fi

    # Bind mount boot_vga=0 on iGPU (only if it currently reads as 1)
    if [ -f "$igpu_boot_vga" ] && [ "$(cat "$igpu_boot_vga" 2>/dev/null)" = "1" ]; then
        mount -n --bind -o ro "${flag_dir}/0" "$igpu_boot_vga"
        echo "${igpu_boot_vga} 0" >> "$BIND_RECORD"
        log "Set boot_vga=0 on iGPU (${igpu_bus})"
    fi

    # Also handle boot_display flags if present
    for gpu_idx in "$EGPU_IDX" "$IGPU_IDX"; do
        local bus="${GPU_BUS_IDS[$gpu_idx]}"
        local boot_display="/sys/bus/pci/devices/${bus}/boot_display"
        if [ -f "$boot_display" ]; then
            if [ "$gpu_idx" -eq "$EGPU_IDX" ]; then
                mount -n --bind -o ro "${flag_dir}/1" "$boot_display"
                echo "${boot_display} 1" >> "$BIND_RECORD"
                log "Set boot_display=1 on eGPU (${bus})"
            else
                if [ "$(cat "$boot_display" 2>/dev/null)" = "1" ]; then
                    mount -n --bind -o ro "${flag_dir}/0" "$boot_display"
                    echo "${boot_display} 0" >> "$BIND_RECORD"
                    log "Set boot_display=0 on iGPU (${bus})"
                fi
            fi
        fi
    done

    log "Boot complete — eGPU is primary"
}

# ─── Cleanup: unmount bind mounts ────────────────────────────────────────────
do_cleanup() {
    do_cleanup_quiet
    echo "Bind mounts cleaned up."
}

do_cleanup_quiet() {
    if [ -f "$BIND_RECORD" ]; then
        while read -r path _val; do
            [ -n "$path" ] && umount -n "$path" 2>/dev/null || true
        done < "$BIND_RECORD"
        rm -f "$BIND_RECORD"
    fi
    # Also check for mounts from old tools
    if [ -f "${USER_HOME}/.config/egpu-manager/bind-paths" ]; then
        while read -r path; do
            [ -n "$path" ] && umount -n "$path" 2>/dev/null || true
        done < "${USER_HOME}/.config/egpu-manager/bind-paths"
        rm -f "${USER_HOME}/.config/egpu-manager/bind-paths"
    fi
    for bp in "${USER_HOME}/.config/all-ways-egpu/bind-paths" /usr/share/all-ways-egpu/bind-paths; do
        if [ -f "$bp" ]; then
            while read -r path; do
                [ -n "$path" ] && umount -n "${path}/boot_vga" 2>/dev/null || true
            done < "$bp"
            rm -f "$bp"
        fi
    done
}

# ─── Terminal Status ─────────────────────────────────────────────────────────
do_status() {
    build_status
}

# ─── System Install (runs as root via pkexec) ────────────────────────────────
do_sys_install() {
    echo "Cleaning up old eGPU services..."

    # Disable and remove old conflicting services
    local old_services=(
        all-ways-egpu-boot-vga.service
        all-ways-egpu-shutdown.service
        all-ways-egpu-set-compositor.service
        all-ways-egpu.service
        all-ways-egpu-igpu.service
        all-ways-egpu-user.service
        egpu-manager-boot.service
        egpu-manager-shutdown.service
    )
    for svc in "${old_services[@]}"; do
        systemctl disable "$svc" 2>/dev/null || true
        rm -f "${SYSTEMD_DIR}/${svc}"
    done

    # Clean up root-owned config from old egpu-manager
    rm -rf "${USER_HOME}/.config/egpu-manager"

    echo "Installing eGPU Switcher services..."

    # Write boot service
    cat > "${SYSTEMD_DIR}/${SVC_BOOT}" << 'EOF'
[Unit]
Description=eGPU Switcher - set eGPU as primary GPU
Before=display-manager.service
After=bolt.service dbus.service systemd-udevd.service

[Service]
Type=oneshot
ExecStart=/home/deck/bin/egpu-switcher.sh boot
TimeoutStartSec=90
StandardOutput=append:/home/deck/.config/egpu-switcher/last-boot.log
StandardError=append:/home/deck/.config/egpu-switcher/last-boot.log

[Install]
WantedBy=multi-user.target
EOF

    # Write shutdown service
    cat > "${SYSTEMD_DIR}/${SVC_SHUTDOWN}" << 'EOF'
[Unit]
Description=eGPU Switcher - cleanup bind mounts
DefaultDependencies=no
Before=halt.target shutdown.target reboot.target

[Service]
Type=oneshot
ExecStart=/home/deck/bin/egpu-switcher.sh cleanup
TimeoutStartSec=30

[Install]
WantedBy=halt.target shutdown.target reboot.target
EOF

    # Enable services
    systemctl daemon-reload
    systemctl enable "$SVC_BOOT" "$SVC_SHUTDOWN"

    echo "Services installed and enabled."
}

# ─── System Uninstall (runs as root via pkexec) ──────────────────────────────
do_sys_uninstall() {
    # Clean up bind mounts
    do_cleanup_quiet

    # Disable and remove services
    systemctl disable "$SVC_BOOT" 2>/dev/null || true
    systemctl disable "$SVC_SHUTDOWN" 2>/dev/null || true
    rm -f "${SYSTEMD_DIR}/${SVC_BOOT}" "${SYSTEMD_DIR}/${SVC_SHUTDOWN}"
    systemctl daemon-reload

    echo "Services removed."
}

# ─── User-space Install (prepare + pkexec for root) ─────────────────────────
do_install() {
    info "Preparing installation..."

    # Fix ~/bin/ ownership if it was created by root (common from old all-ways-egpu installs)
    if [ -d "$BIN_DIR" ] && [ ! -w "$BIN_DIR" ]; then
        info "Fixing ownership of ${BIN_DIR} (currently root-owned)..."
        if [ "$GUI_MODE" -eq 1 ]; then
            gui_popup "Fixing file permissions — password required..."
        fi
        if ! pkexec chown -R deck:deck "$BIN_DIR"; then
            if [ "$GUI_MODE" -eq 1 ]; then
                gui_error "Could not fix ${BIN_DIR} permissions.\n\nTry running in a terminal:\n  sudo chown -R deck:deck ~/bin"
            else
                err "Could not fix ${BIN_DIR} permissions. Try: sudo chown -R deck:deck ~/bin"
            fi
            return 1
        fi
    fi

    # Copy script to ~/bin/
    mkdir -p "$BIN_DIR" "$CONFIG_DIR"
    local script_src
    script_src="$(readlink -f "$0")"
    if ! cp "$script_src" "$BIN_SCRIPT"; then
        if [ "$GUI_MODE" -eq 1 ]; then
            gui_error "Failed to copy script to ${BIN_SCRIPT}.\n\nCheck file permissions."
        else
            err "Failed to copy script to ${BIN_SCRIPT}"
        fi
        return 1
    fi
    chmod +x "$BIN_SCRIPT"
    ok "Script installed to ${BIN_SCRIPT}"

    # Ensure ~/bin is in PATH
    if [ -f "${USER_HOME}/.bashrc" ]; then
        if ! grep -q 'PATH=.*\$HOME/bin' "${USER_HOME}/.bashrc" 2>/dev/null; then
            echo 'export PATH="$HOME/bin:$PATH"' >> "${USER_HOME}/.bashrc"
            info "Added ~/bin to PATH in .bashrc"
        fi
    fi

    # Elevate for system operations
    if [ "$GUI_MODE" -eq 1 ]; then
        gui_popup "Installing services — password required..."
    fi

    if pkexec bash "$BIN_SCRIPT" _sys_install; then
        if [ "$GUI_MODE" -eq 1 ]; then
            gui_msg "eGPU Switcher installed!\n\nYour eGPU will automatically become the primary GPU on every boot.\n\nIf the dock is not connected, it safely does nothing.\n\nReboot to activate, or use 'Switch Now' from the menu."
        else
            ok "Installation complete!"
            info "Reboot to activate, or run: sudo egpu-switcher.sh boot"
        fi
    else
        if [ "$GUI_MODE" -eq 1 ]; then
            gui_error "Installation failed.\n\nTry running from terminal:\n  sudo ${BIN_SCRIPT} _sys_install"
        else
            err "System install failed. Try: sudo ${BIN_SCRIPT} _sys_install"
        fi
        return 1
    fi
}

# ─── User-space Uninstall ────────────────────────────────────────────────────
do_uninstall() {
    if [ "$GUI_MODE" -eq 1 ]; then
        gui_yesno "This will remove eGPU Switcher and all its services.\n\nAre you sure?" || return 0
        gui_popup "Removing services — password required..."
    else
        echo "This will remove eGPU Switcher. Continue? [y/N]"
        read -rp "> " confirm
        [ "$confirm" = "y" ] || return 0
    fi

    if pkexec bash "$BIN_SCRIPT" _sys_uninstall; then
        rm -f "$BIN_SCRIPT"
        rm -rf "$CONFIG_DIR"
        if [ "$GUI_MODE" -eq 1 ]; then
            gui_msg "eGPU Switcher has been uninstalled.\n\nYou can delete egpu-switcher.sh from your Desktop."
        else
            ok "Uninstalled."
        fi
    else
        if [ "$GUI_MODE" -eq 1 ]; then
            gui_error "Uninstall failed."
        else
            err "Uninstall failed."
        fi
    fi
}

# ─── GUI ─────────────────────────────────────────────────────────────────────
do_gui() {
    GUI_MODE=1

    # Trap unexpected errors so the user sees something instead of silent exit
    trap 'gui_error "An unexpected error occurred (line $LINENO).\n\nTry running from terminal for details:\n  bash ~/Desktop/egpu-switcher.sh gui"' ERR

    discover_gpus

    local installed=0
    [ -f "${SYSTEMD_DIR}/${SVC_BOOT}" ] && installed=1

    if [ "$installed" -eq 0 ]; then
        # Not installed — build a quick status and offer install
        local gpu_summary=""
        if [ "$EGPU_IDX" -ge 0 ]; then
            gpu_summary="eGPU detected: ${GPU_NAME[$EGPU_IDX]}\n"
            gpu_summary+="iGPU: ${GPU_NAME[$IGPU_IDX]}\n\n"
        elif [ "${#GPU_BUS_IDS[@]}" -gt 0 ]; then
            gpu_summary="Only internal GPU detected.\nConnect your eGPU dock before installing.\n\n"
        fi

        gui_yesno "${gpu_summary}eGPU Switcher is not installed yet.\n\nInstall now?\n\nThis sets up a boot service that automatically makes your eGPU the primary GPU." || return 0
        do_install || return 1

        # Re-discover after install and fall through to the main menu
        discover_gpus
        installed=1
    fi

    # Build summary for menu header
    local header=""
    if [ "$EGPU_IDX" -ge 0 ]; then
        header+="eGPU: ${GPU_NAME[$EGPU_IDX]}  (boot_vga=${GPU_BOOT_VGA[$EGPU_IDX]})\n"
    else
        header+="eGPU: Not detected\n"
    fi
    if [ "$IGPU_IDX" -ge 0 ]; then
        header+="iGPU: ${GPU_NAME[$IGPU_IDX]}  (boot_vga=${GPU_BOOT_VGA[$IGPU_IDX]})\n"
    fi
    local svc_state
    svc_state=$(systemctl is-active "$SVC_BOOT" 2>/dev/null || echo "not run yet")
    header+="Last boot: ${svc_state}\n"

    while true; do
        local choice
        choice=$(gui_menu "$header" \
            "status"    "View detailed GPU status" \
            "switch"    "Switch to eGPU now (restarts display)" \
            "reinstall" "Reinstall / repair services" \
            "log"       "View last boot log" \
            "uninstall" "Uninstall eGPU Switcher" \
        ) || return 0

        case "$choice" in
            status)
                local st
                st=$(build_status)
                # Strip ANSI codes for GUI
                st=$(echo "$st" | sed 's/\x1b\[[0-9;]*m//g')
                gui_text "$st"
                ;;
            switch)
                if [ "$EGPU_IDX" -lt 0 ]; then
                    gui_error "No eGPU detected.\n\nMake sure the dock is connected and powered on."
                    continue
                fi
                gui_yesno "This will set the eGPU as primary and restart the display manager.\n\nYou will be logged out. Continue?" || continue
                gui_popup "Switching to eGPU — password required..."
                # Single pkexec: run boot swap then restart display manager
                pkexec bash -c "'$BIN_SCRIPT' boot && systemctl restart display-manager.service" 2>/dev/null || true
                return 0
                ;;
            reinstall)
                do_install
                ;;
            log)
                if [ -f "$LOG_FILE" ] && [ -s "$LOG_FILE" ]; then
                    gui_text "$(cat "$LOG_FILE")"
                else
                    gui_msg "No boot log found yet.\n\nThe log is created on the first boot after installation."
                fi
                ;;
            uninstall)
                do_uninstall
                return 0
                ;;
        esac
    done
}

# ─── Main ────────────────────────────────────────────────────────────────────
show_help() {
    echo "egpu-switcher v${VERSION} — Zero-config eGPU for SteamOS"
    echo ""
    echo "Usage: egpu-switcher.sh [command]"
    echo ""
    echo "  (no args)   Launch GUI (in graphical session) or show this help"
    echo "  status      Show GPU and service status"
    echo "  install     Install boot service"
    echo "  uninstall   Remove boot service"
    echo "  gui         Launch GUI"
    echo "  --version   Show version"
    echo "  --help      Show this help"
    echo ""
    echo "After install, the eGPU is automatically set as primary on every boot."
    echo "If the dock is disconnected, it safely does nothing."
}

case "${1:-}" in
    boot)
        do_boot
        ;;
    cleanup)
        do_cleanup
        ;;
    status)
        do_status
        ;;
    _sys_install)
        do_sys_install
        ;;
    _sys_uninstall)
        do_sys_uninstall
        ;;
    install)
        do_install
        ;;
    uninstall)
        do_uninstall
        ;;
    gui)
        GUI_MODE=1
        do_gui
        ;;
    --version|-v|version)
        echo "egpu-switcher v${VERSION}"
        ;;
    --help|-h|help)
        show_help
        ;;
    *)
        # No args: launch GUI if in graphical session, otherwise show help
        if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
            do_gui
        else
            show_help
        fi
        ;;
esac
