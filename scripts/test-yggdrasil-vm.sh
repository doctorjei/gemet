#!/usr/bin/env bash
#
# test-yggdrasil-vm — Minimum-viable VM boot test for the Yggdrasil OCI image
#
# Extracts the rootfs of a locally-available yggdrasil:<ver> OCI image into a
# temp directory, verifies it has the pieces needed for a serial-console boot
# (udev present, serial-getty@ttyS0 enabled), and hands off to test-boot.sh
# for the actual virtiofsd + QEMU heavy lifting.
#
# Usage:
#   test-yggdrasil-vm.sh [options] [-- test-boot-extra-args...]
#
# Options:
#   --image <tag>     OCI image tag to test (default: yggdrasil:<VERSION>)
#   --kernel <path>   Path to vmlinuz (default: build/vmlinuz)
#   --initrd <path>   Path to initramfs (default: build/gemet-initramfs.img)
#   --memory <MB>     VM memory in MB (default: 512)
#   -h, --help        Show this help
#
# Any arguments after `--` are forwarded verbatim to test-boot.sh (for example
# `--dax`, `--no-kvm`, `--no-net`). For fine-grained control, invoke
# test-boot.sh directly against the extracted rootfs.
#
# Requires: podman or docker (for OCI extraction), test-boot.sh, a built
# kernel + initramfs, and everything test-boot.sh itself needs (virtiofsd,
# qemu-system-x86_64, /dev/kvm).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION_FILE="$REPO_ROOT/VERSION"
TEST_BOOT="$SCRIPT_DIR/test-boot.sh"

# ─── Helpers ───────────────────────────────────────────────────────

info()  { echo -e "\033[1;34m>>>\033[0m $*"; }
warn()  { echo -e "\033[1;33mWARN:\033[0m $*" >&2; }
error() { echo -e "\033[1;31mERROR:\033[0m $*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
Usage: test-yggdrasil-vm.sh [options] [-- test-boot-extra-args...]

Extracts yggdrasil:<ver> into a temp rootfs and boots it via test-boot.sh.

Options:
  --image <tag>     OCI image tag to test (default: yggdrasil:<VERSION>)
  --kernel <path>   Path to vmlinuz (default: build/vmlinuz)
  --initrd <path>   Path to initramfs (default: build/gemet-initramfs.img)
  --memory <MB>     VM memory in MB (default: 512)
  -h, --help        Show this help

Arguments after `--` are forwarded to test-boot.sh (e.g. --dax, --no-kvm).
USAGE
    exit "${1:-0}"
}

# ─── Parse arguments ──────────────────────────────────────────────

default_version=""
[[ -f "$VERSION_FILE" ]] && default_version="$(tr -d '[:space:]' < "$VERSION_FILE")"
IMAGE="yggdrasil:${default_version:-latest}"
KERNEL="$REPO_ROOT/build/vmlinuz"
INITRD="$REPO_ROOT/build/gemet-initramfs.img"
MEMORY=512
PASSTHROUGH=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --image)  IMAGE="$2";  shift 2 ;;
        --kernel) KERNEL="$2"; shift 2 ;;
        --initrd) INITRD="$2"; shift 2 ;;
        --memory) MEMORY="$2"; shift 2 ;;
        --)       shift; PASSTHROUGH=("$@"); break ;;
        -h|--help) usage 0 ;;
        *) echo "Error: unknown option: $1" >&2; usage 1 ;;
    esac
done

# ─── Prerequisites ────────────────────────────────────────────────

[[ -x "$TEST_BOOT" ]] || error "test-boot.sh not found or not executable: $TEST_BOOT"
[[ -f "$KERNEL" ]]    || error "kernel not found: $KERNEL (build it: bash scripts/build-kernel.sh <ver>)"
[[ -f "$INITRD" ]]    || error "initramfs not found: $INITRD (build it: bash initramfs/build.sh)"

if command -v podman &>/dev/null; then
    CONTAINER_CMD=podman
elif command -v docker &>/dev/null; then
    CONTAINER_CMD=docker
else
    error "neither podman nor docker found. Install: apt install podman"
fi

$CONTAINER_CMD image inspect "$IMAGE" &>/dev/null || \
    error "OCI image '$IMAGE' not found locally. Build it first: sudo bash rootfs/build-yggdrasil.sh"

# ─── Cleanup ──────────────────────────────────────────────────────

ROOTFS_DIR=""
TEMP_CONTAINER=""

cleanup() {
    if [[ -n "$TEMP_CONTAINER" ]]; then
        $CONTAINER_CMD rm "$TEMP_CONTAINER" &>/dev/null || true
    fi
    if [[ -n "$ROOTFS_DIR" && -d "$ROOTFS_DIR" ]]; then
        rm -rf "$ROOTFS_DIR"
    fi
}
trap cleanup EXIT

# ─── Extract OCI rootfs ───────────────────────────────────────────

ROOTFS_DIR=$(mktemp -d "/tmp/yggdrasil-vm-rootfs.XXXXXX")
TEMP_CONTAINER="yggdrasil-export-$$"

info "Extracting '$IMAGE' rootfs to $ROOTFS_DIR..."
$CONTAINER_CMD create --name "$TEMP_CONTAINER" "$IMAGE" /bin/true >/dev/null
$CONTAINER_CMD export "$TEMP_CONTAINER" | tar -x -C "$ROOTFS_DIR"
$CONTAINER_CMD rm "$TEMP_CONTAINER" >/dev/null
TEMP_CONTAINER=""

# ─── Verify + enable serial console ───────────────────────────────
# Yggdrasil inherits genericcloud's udev, but genericcloud historically does
# NOT enable serial-getty@ttyS0 — without it, no login prompt on the serial
# console that test-boot.sh uses. Known tenkei gotcha.

if [[ ! -d "$ROOTFS_DIR/lib/udev" ]] && [[ ! -d "$ROOTFS_DIR/usr/lib/udev" ]]; then
    error "udev not found in rootfs — Yggdrasil image is missing a critical dep"
fi

GETTY_LINK="$ROOTFS_DIR/etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service"
GETTY_UNIT="$ROOTFS_DIR/lib/systemd/system/serial-getty@.service"
[[ -f "$GETTY_UNIT" ]] || GETTY_UNIT="$ROOTFS_DIR/usr/lib/systemd/system/serial-getty@.service"

if [[ ! -L "$GETTY_LINK" && ! -e "$GETTY_LINK" ]]; then
    if [[ -f "$GETTY_UNIT" ]]; then
        info "Enabling serial-getty@ttyS0.service (not enabled in base image)..."
        mkdir -p "$(dirname "$GETTY_LINK")"
        ln -sf "$GETTY_UNIT" "$GETTY_LINK"
    else
        warn "serial-getty@.service template not found; login on ttyS0 may be unavailable"
    fi
fi

# ─── Hand off to test-boot.sh ─────────────────────────────────────
# We invoke (not exec) test-boot.sh so the trap still fires and cleans up
# the temp rootfs dir when QEMU exits.

info "Handing off to test-boot.sh..."
info "  Image:   $IMAGE"
info "  Rootfs:  $ROOTFS_DIR"
info "  Kernel:  $KERNEL"
info "  Initrd:  $INITRD"
info "  Memory:  ${MEMORY}M"

"$TEST_BOOT" \
    --kernel "$KERNEL" \
    --initrd "$INITRD" \
    --rootfs "$ROOTFS_DIR" \
    --memory "$MEMORY" \
    "${PASSTHROUGH[@]}"
