#!/usr/bin/env bash
#
# test-yggdrasil-disk — Minimum-viable smoke test for the Yggdrasil qcow2
#
# Boots a Yggdrasil qcow2 disk image externally with tenkei's kernel +
# initramfs. No virtiofsd, no shared-memory plumbing — just a plain QEMU
# run with a virtio-blk drive and user-mode networking.
#
# Usage:
#   test-yggdrasil-disk.sh [options]
#
# Options:
#   --disk <path>     qcow2 disk image (default: build/yggdrasil-<VERSION>.qcow2)
#   --kernel <path>   Path to vmlinuz   (default: build/vmlinuz)
#   --initrd <path>   Path to initramfs (default: build/tenkei-initramfs.img)
#   --memory <MB>     VM memory in MB   (default: 512)
#   --ssh-port <port> Host port forwarded to guest SSH (default: 2223)
#   --no-kvm          Disable KVM (slow, but works without /dev/kvm)
#   -h, --help        Show this help
#
# The cmdline passed to the kernel is:
#   console=ttyS0 root=/dev/vda rootfstype=ext4
# which matches the partition-less layout produced by
# rootfs/build-yggdrasil.sh (or scripts/extract-oci.sh --qcow2 from any
# OCI archive). tenkei's initramfs dispatches on root= (see
# initramfs/init).
#
# Default SSH port 2223 is intentionally different from test-boot.sh (2222)
# so both can run concurrently.
#
# Requirements:
#   - qemu-system-x86_64
#   - KVM access (/dev/kvm), unless --no-kvm
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION_FILE="$REPO_ROOT/VERSION"

# ─── Helpers ──────────────────────────────────────────────────────
info()  { echo -e "\033[1;34m>>>\033[0m $*"; }
warn()  { echo -e "\033[1;33mWARN:\033[0m $*" >&2; }
error() { echo -e "\033[1;31mERROR:\033[0m $*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
Usage: test-yggdrasil-disk.sh [options]

Boots a Yggdrasil qcow2 image externally with tenkei's kernel/initramfs.

Options:
  --disk <path>     qcow2 disk image (default: build/yggdrasil-<VERSION>.qcow2)
  --kernel <path>   Path to vmlinuz   (default: build/vmlinuz)
  --initrd <path>   Path to initramfs (default: build/tenkei-initramfs.img)
  --memory <MB>     VM memory in MB   (default: 512)
  --ssh-port <port> Host port forwarded to guest SSH (default: 2223)
  --no-kvm          Disable KVM (slow, but works without /dev/kvm)
  -h, --help        Show this help

Serial console: -nographic. Press Ctrl-A X to exit QEMU.
USAGE
    exit "${1:-0}"
}

# ─── Parse arguments ──────────────────────────────────────────────

default_version=""
[[ -f "$VERSION_FILE" ]] && default_version="$(tr -d '[:space:]' < "$VERSION_FILE")"

DISK="$REPO_ROOT/build/yggdrasil-${default_version:-latest}.qcow2"
KERNEL="$REPO_ROOT/build/vmlinuz"
INITRD="$REPO_ROOT/build/tenkei-initramfs.img"
MEMORY=512
SSH_PORT=2223
USE_KVM=true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --disk)     DISK="$2"; shift 2 ;;
        --kernel)   KERNEL="$2"; shift 2 ;;
        --initrd)   INITRD="$2"; shift 2 ;;
        --memory)   MEMORY="$2"; shift 2 ;;
        --ssh-port) SSH_PORT="$2"; shift 2 ;;
        --no-kvm)   USE_KVM=false; shift ;;
        -h|--help)  usage 0 ;;
        *)          echo "Error: unknown option: $1" >&2; usage 1 ;;
    esac
done

# ─── Prerequisites ────────────────────────────────────────────────

[[ -f "$DISK" ]]   || error "disk not found: $DISK (build it: bash rootfs/build-yggdrasil.sh)"
[[ -f "$KERNEL" ]] || error "kernel not found: $KERNEL (build it: bash scripts/build-kernel.sh <ver>)"
[[ -f "$INITRD" ]] || error "initramfs not found: $INITRD (build it: bash initramfs/build.sh)"

command -v qemu-system-x86_64 &>/dev/null || \
    error "qemu-system-x86_64 not found. Install: apt install qemu-system-x86"

if $USE_KVM; then
    if [[ ! -e /dev/kvm ]]; then
        warn "/dev/kvm not found — falling back to TCG (slow)"
        USE_KVM=false
    fi
fi

# ─── Launch QEMU ──────────────────────────────────────────────────

kvm_args=()
if $USE_KVM; then
    kvm_args=(-enable-kvm -cpu host)
fi

net_args=(
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22"
    -device virtio-net-pci,netdev=net0
)

info "Launching QEMU..."
info "  Disk:    $DISK"
info "  Kernel:  $KERNEL"
info "  Initrd:  $INITRD"
info "  Memory:  ${MEMORY}M"
info "  KVM:     $USE_KVM"
info "  Network: user-mode (SLIRP), guest 10.0.2.x"
info "  SSH:     ssh -p ${SSH_PORT} root@127.0.0.1"
info ""
info "Press Ctrl-A X to exit QEMU."
info ""

qemu-system-x86_64 \
    -machine q35 \
    -kernel "$KERNEL" \
    -initrd "$INITRD" \
    -m "$MEMORY" \
    "${kvm_args[@]}" \
    -drive "file=${DISK},format=qcow2,if=virtio" \
    "${net_args[@]}" \
    -nographic \
    -append "console=ttyS0 root=/dev/vda rootfstype=ext4"
