#!/usr/bin/env bash
#
# test-boot — Boot-test a tenkei kernel + initramfs with QEMU and virtiofs
#
# Launches virtiofsd to serve a rootfs directory, then boots QEMU with the
# tenkei kernel and initramfs. The VM mounts the rootfs via virtiofs and
# switch_roots into it.
#
# Usage:
#   test-boot.sh --kernel <vmlinuz> --initrd <initramfs> --rootfs <dir>
#   test-boot.sh -k <vmlinuz> -i <initramfs> -r <dir>
#
# Quick start:
#   # 1. Build the initramfs
#   bash initramfs/build.sh
#
#   # 2. Build a kernel (or use a prebuilt one)
#   bash scripts/build-kernel.sh 6.12.8
#
#   # 3. Create a test rootfs
#   sudo debootstrap --variant=minbase bookworm /tmp/test-rootfs
#
#   # 4. Boot it
#   bash scripts/test-boot.sh \
#       --kernel /path/to/vmlinuz \
#       --initrd initramfs/tenkei-initramfs.img \
#       --rootfs /tmp/test-rootfs
#
# Requirements:
#   - qemu-system-x86_64
#   - virtiofsd (Debian: apt install virtiofsd; path: /usr/libexec/virtiofsd)
#   - KVM access (/dev/kvm)
#
set -euo pipefail

# ─── Helpers ───────────────────────────────────────────────────────

info()  { echo -e "\033[1;34m>>>\033[0m $*"; }
warn()  { echo -e "\033[1;33mWARN:\033[0m $*"; }
error() { echo -e "\033[1;31mERROR:\033[0m $*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
Usage: test-boot.sh --kernel <vmlinuz> --initrd <initramfs> --rootfs <dir>

Options:
  -k, --kernel <path>   Path to vmlinuz kernel image
  -i, --initrd <path>   Path to initramfs image
  -r, --rootfs <dir>    Path to rootfs directory to serve via virtiofs
  -m, --memory <size>   VM memory in MB (default: 512)
      --no-kvm          Disable KVM (slow, but works without /dev/kvm)
  -h, --help            Show this help

The script starts virtiofsd in the background and cleans it up on exit.
Serial console is connected to the terminal (-nographic).
Press Ctrl-A X to exit QEMU.
USAGE
    exit "${1:-0}"
}

cleanup() {
    if [[ -n "${VIRTIOFSD_PID:-}" ]]; then
        info "Stopping virtiofsd (PID ${VIRTIOFSD_PID})..."
        kill "$VIRTIOFSD_PID" 2>/dev/null || true
        wait "$VIRTIOFSD_PID" 2>/dev/null || true
    fi
    if [[ -n "${SOCKET_PATH:-}" && -S "$SOCKET_PATH" ]]; then
        rm -f "$SOCKET_PATH"
    fi
}
trap cleanup EXIT

# ─── Find virtiofsd ───────────────────────────────────────────────

find_virtiofsd() {
    local candidates=(
        /usr/libexec/virtiofsd
        /usr/lib/virtiofsd
        /usr/bin/virtiofsd
    )
    for path in "${candidates[@]}"; do
        if [[ -x "$path" ]]; then
            echo "$path"
            return
        fi
    done
    # Try PATH as last resort
    if command -v virtiofsd &>/dev/null; then
        command -v virtiofsd
        return
    fi
    error "virtiofsd not found. Install it: apt install virtiofsd"
}

# ─── Parse arguments ──────────────────────────────────────────────

kernel=""
initrd=""
rootfs=""
memory=512
use_kvm=true

while [[ $# -gt 0 ]]; do
    case "$1" in
        -k|--kernel)  kernel="$2"; shift 2 ;;
        -i|--initrd)  initrd="$2"; shift 2 ;;
        -r|--rootfs)  rootfs="$2"; shift 2 ;;
        -m|--memory)  memory="$2"; shift 2 ;;
        --no-kvm)     use_kvm=false; shift ;;
        -h|--help)    usage 0 ;;
        *)            error "Unknown option: $1" ;;
    esac
done

[[ -n "$kernel" ]] || { echo "Error: --kernel is required"; usage 1; }
[[ -n "$initrd" ]] || { echo "Error: --initrd is required"; usage 1; }
[[ -n "$rootfs" ]] || { echo "Error: --rootfs is required"; usage 1; }

[[ -f "$kernel" ]] || error "Kernel not found: ${kernel}"
[[ -f "$initrd" ]] || error "Initrd not found: ${initrd}"
[[ -d "$rootfs" ]] || error "Rootfs not found: ${rootfs}"

# ─── Check dependencies ───────────────────────────────────────────

command -v qemu-system-x86_64 &>/dev/null || \
    error "qemu-system-x86_64 not found. Install: apt install qemu-system-x86"

virtiofsd_bin="$(find_virtiofsd)"
info "Using virtiofsd: ${virtiofsd_bin}"

if [[ "$use_kvm" == "true" ]]; then
    [[ -e /dev/kvm ]] || {
        warn "/dev/kvm not found — falling back to TCG (slow)"
        use_kvm=false
    }
fi

# ─── Start virtiofsd ──────────────────────────────────────────────

SOCKET_PATH="/tmp/tenkei-vfs-$$.sock"

info "Starting virtiofsd..."
info "  Socket: ${SOCKET_PATH}"
info "  Rootfs: ${rootfs}"

"$virtiofsd_bin" \
    --socket-path="$SOCKET_PATH" \
    --shared-dir="$rootfs" \
    --cache=auto &
VIRTIOFSD_PID=$!

# Wait for socket to appear
for i in $(seq 1 30); do
    [[ -S "$SOCKET_PATH" ]] && break
    sleep 0.1
done
[[ -S "$SOCKET_PATH" ]] || error "virtiofsd socket did not appear"

# ─── Launch QEMU ──────────────────────────────────────────────────

kvm_args=""
if [[ "$use_kvm" == "true" ]]; then
    kvm_args="-enable-kvm -cpu host"
fi

info "Launching QEMU..."
info "  Kernel:  ${kernel}"
info "  Initrd:  ${initrd}"
info "  Memory:  ${memory}M"
info "  KVM:     ${use_kvm}"
info ""
info "Press Ctrl-A X to exit QEMU."
info ""

# shellcheck disable=SC2086
qemu-system-x86_64 \
    -kernel "$kernel" \
    -initrd "$initrd" \
    -m "$memory" \
    ${kvm_args} \
    -nographic \
    -chardev "socket,id=vfs,path=${SOCKET_PATH}" \
    -device "vhost-user-fs-pci,chardev=vfs,tag=rootfs" \
    -object "memory-backend-memfd,id=mem,size=${memory}M,share=on" \
    -numa "node,memdev=mem" \
    -append "console=ttyS0 rootfstype=virtiofs root=rootfs"
