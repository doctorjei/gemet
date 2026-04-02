#!/usr/bin/env bash
#
# create-test-rootfs — Create a minimal Debian rootfs for tenkei VM boot testing
#
# Runs debootstrap to create a minimal rootfs with udev, systemd, serial
# console, and DHCP networking. The result is ready to boot with test-boot.sh.
#
# Usage:
#   sudo bash scripts/create-test-rootfs.sh
#   sudo bash scripts/create-test-rootfs.sh /tmp/my-rootfs
#   sudo bash scripts/create-test-rootfs.sh --suite trixie --password secret /tmp/my-rootfs
#
# Requirements:
#   - debootstrap (apt install debootstrap)
#   - Root access (debootstrap requires it)
#
set -euo pipefail

# ─── Helpers ───────────────────────────────────────────────────────

info()  { echo -e "\033[1;34m>>>\033[0m $*"; }
warn()  { echo -e "\033[1;33mWARN:\033[0m $*" >&2; }
error() { echo -e "\033[1;31mERROR:\033[0m $*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
Usage: create-test-rootfs.sh [options] [<output-dir>]

Arguments:
  <output-dir>            Path for the new rootfs (default: /tmp/test-rootfs)

Options:
  --suite <name>          Debian suite to bootstrap (default: bookworm)
  --password <pw>         Root password for the VM (default: test)
  -h, --help              Show this help

The script installs a minimal Debian rootfs with udev, systemd, serial console
access, and DHCP networking — everything needed for a tenkei virtiofs boot.
USAGE
    exit "${1:-0}"
}

# ─── Parse arguments ──────────────────────────────────────────────

output_dir="/tmp/test-rootfs"
suite="bookworm"
password="test"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --suite)     suite="$2"; shift 2 ;;
        --password)  password="$2"; shift 2 ;;
        -h|--help)   usage 0 ;;
        -*)          error "Unknown option: $1" ;;
        *)           output_dir="$1"; shift ;;
    esac
done

# ─── Pre-checks ──────────────────────────────────────────────────

[[ "$(id -u)" == "0" ]] || \
    error "This script must be run as root (debootstrap requires it)."

command -v debootstrap &>/dev/null || \
    error "debootstrap not found. Install it: apt install debootstrap"

if [[ -d "$output_dir" ]]; then
    warn "Output directory already exists: ${output_dir}"
    error "Delete it first (rm -rf ${output_dir}) and re-run."
fi

# ─── Bootstrap base system ───────────────────────────────────────

info "Bootstrapping ${suite} into ${output_dir}..."
debootstrap --variant=minbase "$suite" "$output_dir"

# ─── Install required packages ───────────────────────────────────

info "Installing udev and systemd-sysv..."
chroot "$output_dir" apt-get install -y udev systemd-sysv

# ─── Enable services ────────────────────────────────────────────

info "Enabling systemd-networkd and serial console..."
chroot "$output_dir" systemctl enable \
    systemd-networkd \
    serial-getty@ttyS0.service

# ─── Set root password ──────────────────────────────────────────

info "Setting root password..."
chroot "$output_dir" bash -c "echo root:${password} | chpasswd"

# ─── Configure networking ───────────────────────────────────────

info "Configuring DHCP networking..."
mkdir -p "${output_dir}/etc/systemd/network"

cat > "${output_dir}/etc/systemd/network/80-dhcp.network" <<'EOF'
[Match]
Type=ether

[Network]
DHCP=yes
EOF

echo "nameserver 10.0.2.3" > "${output_dir}/etc/resolv.conf"

# ─── Configure fstab ────────────────────────────────────────────

echo "# Empty -- no block devices in tenkei VMs" \
    > "${output_dir}/etc/fstab"

# ─── Summary ────────────────────────────────────────────────────

info "Test rootfs ready: ${output_dir}"
info ""
info "Boot with:"
info "  sudo bash scripts/test-boot.sh \\"
info "    --kernel build/vmlinuz \\"
info "    --initrd build/tenkei-initramfs.img \\"
info "    --rootfs ${output_dir}"
