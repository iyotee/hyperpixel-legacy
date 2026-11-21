
#!/usr/bin/env bash
#
# HyperPixel 4 Square LEGACY - Complete Installer
#
# Hardware:
#   Raspberry Pi 3 Model A Plus Rev 1.0
#   Pimoroni HyperPixel 4 Square (pre-2021 / non-XP)
#
# OS:
#   Debian 13 / Raspberry Pi OS 64-bit
#
# Repository:
#   https://github.com/pimoroni/hyperpixel4
#   Branch: square
#
# Usage:
#   sudo bash restore-hyperpixel-legacy.sh
#   sudo bash restore-hyperpixel-legacy.sh --check
#   sudo bash restore-hyperpixel-legacy.sh --repair
#   sudo bash restore-hyperpixel-legacy.sh --rollback
#
# Does not reboot automatically.

set -Eeuo pipefail
IFS=$'\n\t'
umask 022

readonly SCRIPT_VERSION="2.0.0"
readonly REPO_URL="https://github.com/pimoroni/hyperpixel4"
readonly REPO_BRANCH="square"
readonly SOURCE_DIR="/opt/hyperpixel4-legacy-source"

readonly BOOT_DIR="/boot/firmware"
readonly CONFIG="${BOOT_DIR}/config.txt"
readonly OVERLAY_DIR="${BOOT_DIR}/overlays"
readonly OVERLAY="${OVERLAY_DIR}/hyperpixel4.dtbo"

readonly BINARY="/usr/bin/hyperpixel4-init"
readonly SERVICE="/etc/systemd/system/hyperpixel4-init.service"
readonly UDEV="/etc/udev/rules.d/98-hyperpixel4-square-calibration.rules"

readonly STATE_DIR="/var/lib/hyperpixel-legacy"
readonly BACKUP_ROOT="/var/backups/hyperpixel-legacy"

ACTION="${1:-install}"
BACKUP=""
SOURCE_COMMIT=""

log()  { printf '\n[INFO] %s\n' "$*"; }
ok()   { printf '[ OK ] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die()  { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

on_error() {
    local line="$1"
    printf '\n[ERROR] Script failed at line %s.\n' "$line" >&2
    if [[ -n "$BACKUP" && -d "$BACKUP" ]]; then
        printf '[INFO] Backup available: %s\n' "$BACKUP" >&2
    fi
}
trap 'on_error "$LINENO"' ERR

usage() {
    cat <<EOF
HyperPixel 4 Square Legacy Installer v${SCRIPT_VERSION}

Usage:
  sudo bash $0              Install / restore
  sudo bash $0 --repair     Repair installation
  sudo bash $0 --check      Read-only diagnostic
  sudo bash $0 --rollback   Restore previous system files

No automatic reboot is performed.
EOF
}

require_root() {
    [[ "$EUID" -eq 0 ]] || die "Run this script with sudo."
}

check_board() {
    log "Checking Raspberry Pi hardware"

    [[ -r /proc/device-tree/model ]] ||
        die "Cannot identify Raspberry Pi model."

    local model
    model="$(tr -d '\0' </proc/device-tree/model)"

    [[ "$model" == "Raspberry Pi 3 Model A Plus Rev 1.0" ]] ||
        die "Unsupported board: ${model}"

    ok "$model"
}

check_os() {
    log "Checking operating system"

    [[ -r /etc/os-release ]] ||
        die "Cannot identify operating system."

    # shellcheck disable=SC1091
    source /etc/os-release

    [[ "${VERSION_ID:-}" == 13* ]] ||
        die "This installer targets Debian 13. Detected: ${PRETTY_NAME:-unknown}"

    [[ "${ID:-}" == "debian" || "${ID:-}" == "raspbian" ]] ||
        die "Unsupported distribution ID: ${ID:-unknown}"

    [[ "$(uname -m)" == "aarch64" ]] ||
        die "Expected an ARM64 kernel."

    [[ "$(dpkg --print-architecture)" == "arm64" ]] ||
        die "Expected an ARM64 userspace."

    [[ -d "$BOOT_DIR" && -f "$CONFIG" ]] ||
        die "Missing ${CONFIG}. This installer requires the Raspberry Pi firmware boot layout."

    [[ -d "$OVERLAY_DIR" ]] ||
        die "Missing overlay directory: ${OVERLAY_DIR}"

    ok "${PRETTY_NAME:-Debian 13}"
    ok "ARM64 kernel and userspace"
    ok "Raspberry Pi firmware boot layout"
}

check_arm32_compat() {
    log "Checking ARM32 kernel compatibility"

    local compat=""

    if [[ -r /proc/config.gz ]]; then
        compat="$(zcat /proc/config.gz | grep -m1 '^CONFIG_COMPAT=' || true)"
    fi

    if [[ -z "$compat" && -r "/boot/config-$(uname -r)" ]]; then
        compat="$(grep -m1 '^CONFIG_COMPAT=' "/boot/config-$(uname -r)" || true)"
    fi

    [[ "$compat" == "CONFIG_COMPAT=y" ]] ||
        die "CONFIG_COMPAT=y not found. The ARM32 initialization binary cannot be assumed to run."

    ok "CONFIG_COMPAT=y"
}

install_dependencies() {
    log "Checking required packages"

    local missing=()

    command -v git >/dev/null 2>&1 || missing+=(git)
    command -v dtc >/dev/null 2>&1 || missing+=(device-tree-compiler)
    command -v readelf >/dev/null 2>&1 || missing+=(binutils)
    command -v python3 >/dev/null 2>&1 || missing+=(python3)

    if ((${#missing[@]})); then
        log "Installing missing packages: ${missing[*]}"
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y --no-install-recommends "${missing[@]}"
    else
        ok "All required packages are installed"
    fi
}

prepare_repository() {
    log "Preparing official Pimoroni repository"

    if [[ ! -d "$SOURCE_DIR/.git" ]]; then
        if [[ -e "$SOURCE_DIR" ]]; then
            die "${SOURCE_DIR} exists but is not a Git repository. Move it before continuing."
        fi

        mkdir -p "$(dirname "$SOURCE_DIR")"

        git clone \
            --depth 1 \
            --single-branch \
            --branch "$REPO_BRANCH" \
            "$REPO_URL" \
            "$SOURCE_DIR"
    else
        local remote branch

        remote="$(git -C "$SOURCE_DIR" remote get-url origin)"
        branch="$(git -C "$SOURCE_DIR" branch --show-current)"

        [[ "$remote" == "$REPO_URL" ]] ||
            die "Existing source directory has an unexpected Git remote: $remote"

        [[ "$branch" == "$REPO_BRANCH" ]] ||
            die "Existing source directory is not on branch ${REPO_BRANCH}."
    fi

    SOURCE_COMMIT="$(git -C "$SOURCE_DIR" rev-parse HEAD)"

    [[ -f "$SOURCE_DIR/src/hyperpixel4.dts" ]] ||
        die "Missing legacy Device Tree source."

    [[ -f "$SOURCE_DIR/dist/hyperpixel4-init" ]] ||
        die "Missing official initialization binary."

    [[ -f "$SOURCE_DIR/dist/hyperpixel4-init.service" ]] ||
        die "Missing official systemd service."

    [[ -f "$SOURCE_DIR/dist/98-hyperpixel4-square-calibration.rules" ]] ||
        die "Missing official touchscreen calibration rules."

    ok "Repository branch: ${REPO_BRANCH}"
    ok "Commit: ${SOURCE_COMMIT}"
}

verify_binary() {
    log "Verifying initialization binary"

    local elf
    elf="$(readelf -h "$SOURCE_DIR/dist/hyperpixel4-init")"

    grep -q 'Class:.*ELF32' <<<"$elf" ||
        die "Initialization binary is not ELF32."

    grep -q 'Machine:.*ARM' <<<"$elf" ||
        die "Initialization binary is not ARM."

    grep -q 'Version5 EABI' <<<"$elf" ||
        die "Unexpected ARM ABI."

    ok "32-bit ARM EABI binary verified"
}

build_overlay() {
    log "Compiling legacy Device Tree overlay"

    local build_dir
    build_dir="$(mktemp -d)"

    if ! dtc -@ -I dts -O dtb \
        -o "$build_dir/hyperpixel4.dtbo" \
        "$SOURCE_DIR/src/hyperpixel4.dts" \
        2>"$build_dir/dtc.log"; then
        cat "$build_dir/dtc.log" >&2
        rm -rf "$build_dir"
        die "Device Tree compilation failed."
    fi

    [[ -s "$build_dir/hyperpixel4.dtbo" ]] ||
        die "Compiled overlay is empty."

    install -m 0644 \
        "$build_dir/hyperpixel4.dtbo" \
        "$OVERLAY"

    if [[ -s "$build_dir/dtc.log" ]]; then
        warn "Device Tree compiler reported warnings:"
        cat "$build_dir/dtc.log"
    fi

    rm -rf "$build_dir"

    ok "Legacy overlay compiled and installed"
}

create_backup() {
    log "Creating timestamped backup"

    mkdir -p "$BACKUP_ROOT" "$STATE_DIR"

    BACKUP="${BACKUP_ROOT}/backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP"

    local enabled="not-found"
    enabled="$(systemctl is-enabled hyperpixel4-init.service 2>/dev/null || true)"
    [[ -n "$enabled" ]] || enabled="not-found"

    printf 'service_enabled=%s\n' "$enabled" > "$BACKUP/manifest"

    backup_file() {
        local key="$1"
        local path="$2"

        if [[ -e "$path" ]]; then
            printf '%s=1\n' "$key" >> "$BACKUP/manifest"
            cp -a "$path" "$BACKUP/$key"
        else
            printf '%s=0\n' "$key" >> "$BACKUP/manifest"
        fi
    }

    backup_file config "$CONFIG"
    backup_file overlay "$OVERLAY"
    backup_file binary "$BINARY"
    backup_file service "$SERVICE"
    backup_file udev "$UDEV"

    printf '%s\n' "$BACKUP" > "$STATE_DIR/last-backup"

    ok "Backup: $BACKUP"
}

install_components() {
    log "Installing HyperPixel legacy components"

    install -m 0755 \
        "$SOURCE_DIR/dist/hyperpixel4-init" \
        "$BINARY"

    install -m 0644 \
        "$SOURCE_DIR/dist/hyperpixel4-init.service" \
        "$SERVICE"

    install -m 0644 \
        "$SOURCE_DIR/dist/98-hyperpixel4-square-calibration.rules" \
        "$UDEV"

    ok "LCD initialization binary installed"
    ok "Systemd service installed"
    ok "Touchscreen UDEV rules installed"
}

configure_boot() {
    log "Configuring legacy DPI and GPIO interfaces"

    python3 - "$CONFIG" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()

begin = "# BEGIN HYPERPIXEL LEGACY MANAGED"
end = "# END HYPERPIXEL LEGACY MANAGED"

lines = text.splitlines()
result = []
inside = False

for line in lines:
    stripped = line.strip()

    if stripped == begin:
        if inside:
            raise SystemExit("Nested managed configuration block.")
        inside = True
        continue

    if stripped == end:
        if not inside:
            raise SystemExit("Unexpected end marker.")
        inside = False
        continue

    if not inside:
        result.append(line)

if inside:
    raise SystemExit("Unclosed managed configuration block.")

# Remove previous active HyperPixel settings.
managed_keys = {
    "dtoverlay",
    "overscan_left",
    "overscan_right",
    "overscan_top",
    "overscan_bottom",
    "framebuffer_width",
    "framebuffer_height",
    "enable_dpi_lcd",
    "display_default_lcd",
    "dpi_group",
    "dpi_mode",
    "dpi_output_format",
    "hdmi_timings",
}

clean = []

for line in result:
    stripped = line.strip()

    if not stripped or stripped.startswith("#") or "=" not in stripped:
        clean.append(line)
        continue

    key, value = [part.strip() for part in stripped.split("=", 1)]

    if key == "dtoverlay":
        overlay_name = value.split(",", 1)[0]

        if overlay_name == "hyperpixel4":
            continue

        if overlay_name in {
            "vc4-kms-v3d",
            "vc4-kms-dpi-hyperpixel4sq",
        }:
            clean.append("# Disabled for legacy HyperPixel: " + stripped)
            continue

    if key == "dtparam":
        params = [p.strip() for p in value.split(",")]
        if any(p in {"i2c_arm=on", "spi=on"} for p in params):
            clean.append("# Disabled for legacy HyperPixel: " + stripped)
            continue

    if key in managed_keys:
        continue

    clean.append(line)

# Ensure a final [all] section so the settings apply to this Pi.
clean.extend([
    "",
    "[all]",
    begin,
    "# Pimoroni HyperPixel 4 Square - legacy / pre-2021",
    "dtoverlay=hyperpixel4",
    "overscan_left=0",
    "overscan_right=0",
    "overscan_top=0",
    "overscan_bottom=0",
    "framebuffer_width=720",
    "framebuffer_height=720",
    "enable_dpi_lcd=1",
    "display_default_lcd=1",
    "dpi_group=2",
    "dpi_mode=87",
    "dpi_output_format=0x7f226",
    "hdmi_timings=720 0 15 15 15 720 0 10 10 10 0 0 0 60 0 35113500 6",
    end,
    "",
])

path.write_text("\n".join(clean))
PY

    ok "Legacy display configuration written"
}

enable_services() {
    log "Activating system services"

    systemctl daemon-reload
    udevadm control --reload-rules
    systemctl enable hyperpixel4-init.service

    ok "LCD initialization service enabled for next boot"
    ok "UDEV rules reloaded"
}

validate_installation() {
    log "Validating installation"

    [[ -x "$BINARY" ]] ||
        die "Initialization binary missing or not executable."

    [[ -f "$SERVICE" ]] ||
        die "Systemd service missing."

    [[ -f "$UDEV" ]] ||
        die "UDEV rules missing."

    [[ -s "$OVERLAY" ]] ||
        die "Legacy overlay missing or empty."

    systemctl is-enabled --quiet hyperpixel4-init.service ||
        die "Systemd service is not enabled."

    python3 - "$CONFIG" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text()
active = [
    line.strip() for line in text.splitlines()
    if line.strip() and not line.lstrip().startswith("#")
]

required = [
    "dtoverlay=hyperpixel4",
    "framebuffer_width=720",
    "framebuffer_height=720",
    "enable_dpi_lcd=1",
    "display_default_lcd=1",
    "dpi_group=2",
    "dpi_mode=87",
    "dpi_output_format=0x7f226",
    "hdmi_timings=720 0 15 15 15 720 0 10 10 10 0 0 0 60 0 35113500 6",
]

for item in required:
    count = active.count(item)
    if count != 1:
        raise SystemExit(f"Expected exactly one active setting: {item} (found {count})")

for line in active:
    if line.startswith("dtoverlay=vc4-kms-dpi-hyperpixel4sq"):
        raise SystemExit("KMS HyperPixel Square overlay is still active.")

    if line.startswith("dtoverlay=vc4-kms-v3d"):
        raise SystemExit("KMS V3D overlay is still active.")

    if line == "dtparam=i2c_arm=on" or line == "dtparam=spi=on":
        raise SystemExit(f"Conflicting hardware interface still active: {line}")

print("Boot configuration validated.")
PY

    ok "All installation checks passed"
}

check_installation() {
    echo
    echo "=========================================="
    echo " HYPERPIXEL LEGACY - DIAGNOSTIC"
    echo "=========================================="

    echo
    echo "=== HARDWARE ==="
    tr -d '\0' </proc/device-tree/model || true

    echo
    echo "=== OS ==="
    cat /etc/os-release | grep -E '^(PRETTY_NAME|VERSION_ID)=' || true

    echo
    echo "=== KERNEL ==="
    uname -a

    echo
    echo "=== SOURCE REPOSITORY ==="
    if [[ -d "$SOURCE_DIR/.git" ]]; then
        git -C "$SOURCE_DIR" branch --show-current
        git -C "$SOURCE_DIR" rev-parse HEAD
    else
        echo "Not installed"
    fi

    echo
    echo "=== INSTALLED FILES ==="
    for f in "$BINARY" "$SERVICE" "$UDEV" "$OVERLAY"; do
        if [[ -e "$f" ]]; then
            ls -lh "$f"
        else
            echo "MISSING: $f"
        fi
    done

    echo
    echo "=== SYSTEMD ==="
    systemctl status hyperpixel4-init.service --no-pager || true

    echo
    echo "=== BOOT CONFIGURATION ==="
    grep -nE 'HyperPixel|dtoverlay=hyperpixel4|framebuffer_(width|height)|dpi_|hdmi_timings|dtparam=(i2c_arm|spi)' "$CONFIG" || true

    echo
    echo "=== DRM ==="
    ls -la /sys/class/drm/ 2>/dev/null || true

    echo
    echo "=== I2C ==="
    ls -la /sys/bus/i2c/devices/ 2>/dev/null || true

    echo
    echo "=== SPI ==="
    ls -la /sys/bus/spi/devices/ 2>/dev/null || true

    echo
    echo "=== LAST BOOT SERVICE LOG ==="
    journalctl -u hyperpixel4-init.service -b --no-pager 2>/dev/null || true
}

rollback() {
    require_root

    [[ -f "$STATE_DIR/last-backup" ]] ||
        die "No previous backup reference found."

    BACKUP="$(cat "$STATE_DIR/last-backup")"

    [[ -d "$BACKUP" && -f "$BACKUP/manifest" ]] ||
        die "Backup directory or manifest missing: $BACKUP"

    log "Rolling back from $BACKUP"

    local service_enabled
    service_enabled="$(grep '^service_enabled=' "$BACKUP/manifest" | cut -d= -f2-)"

    systemctl disable hyperpixel4-init.service 2>/dev/null || true

    restore_file() {
        local key="$1"
        local path="$2"
        local existed

        existed="$(grep "^${key}=" "$BACKUP/manifest" | cut -d= -f2-)"

        if [[ "$existed" == "1" ]]; then
            cp -a "$BACKUP/$key" "$path"
        else
            rm -f "$path"
        fi
    }

    restore_file config "$CONFIG"
    restore_file overlay "$OVERLAY"
    restore_file binary "$BINARY"
    restore_file service "$SERVICE"
    restore_file udev "$UDEV"

    systemctl daemon-reload
    udevadm control --reload-rules

    if [[ "$service_enabled" == "enabled" ]]; then
        systemctl enable hyperpixel4-init.service
    fi

    ok "Previous system files restored."
    echo "Reboot required to apply the previous boot configuration."
}

main() {
    case "$ACTION" in
        --help|-h)
            usage
            exit 0
            ;;
        --check)
            check_installation
            exit 0
            ;;
        --rollback)
            rollback
            exit 0
            ;;
        install|--repair)
            ;;
        *)
            usage
            die "Unknown action: $ACTION"
            ;;
    esac

    require_root

    echo
    echo "=========================================="
    echo " HYPERPIXEL LEGACY INSTALLER v${SCRIPT_VERSION}"
    echo " Raspberry Pi 3 Model A Plus"
    echo " HyperPixel 4 Square - pre-2021"
    echo "=========================================="

    check_board
    check_os
    check_arm32_compat
    install_dependencies
    prepare_repository
    verify_binary

    create_backup
    build_overlay
    install_components
    configure_boot
    enable_services
    validate_installation

    echo
    echo "=========================================="
    echo " INSTALLATION SUCCESSFUL"
    echo "=========================================="
    echo
    echo "Repository: ${SOURCE_DIR}"
    echo "Branch:     ${REPO_BRANCH}"
    echo "Commit:     ${SOURCE_COMMIT}"
    echo "Overlay:    ${OVERLAY}"
    echo "Backup:     ${BACKUP}"
    echo
    echo "No reboot was performed."
    echo
    echo "Next step:"
    echo "  sudo reboot"
    echo
    echo "After reboot:"
    echo "  sudo bash $0 --check"
    echo
    echo "Rollback:"
    echo "  sudo bash $0 --rollback"
    echo
}

main "$@"
