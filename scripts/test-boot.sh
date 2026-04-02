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
#   sudo bash scripts/create-test-rootfs.sh /tmp/test-rootfs
#
#   # 4. Boot it (networking + SSH forwarding enabled by default)
#   bash scripts/test-boot.sh \
#       --kernel /path/to/vmlinuz \
#       --initrd initramfs/tenkei-initramfs.img \
#       --rootfs /tmp/test-rootfs
#
#   # 5. SSH in from another terminal
#   ssh -p 2222 root@127.0.0.1
#
# Requirements:
#   - qemu-system-x86_64
#   - virtiofsd (Debian: apt install virtiofsd; path: /usr/libexec/virtiofsd)
#   - KVM access (/dev/kvm)
#
set -euo pipefail

# ─── Helpers ───────────────────────────────────────────────────────

info()  { echo -e "\033[1;34m>>>\033[0m $*"; }
warn()  { echo -e "\033[1;33mWARN:\033[0m $*" >&2; }
error() { echo -e "\033[1;31mERROR:\033[0m $*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
Usage: test-boot.sh --kernel <vmlinuz> --initrd <initramfs> --rootfs <dir>

Options:
  -k, --kernel <path>   Path to vmlinuz kernel image
  -i, --initrd <path>   Path to initramfs image
  -r, --rootfs <dir>    Path to rootfs directory to serve via virtiofs
  -m, --memory <size>   VM memory in MB (default: 512)
      --dax [size]      Enable DAX (direct access) with optional cache size
                        (default: 256M). Sets virtiofsd --cache=always.
      --no-kvm          Disable KVM (slow, but works without /dev/kvm)
      --no-net          Disable networking
      --ssh-port <port> Host port forwarded to guest SSH (default: 2222)
  -h, --help            Show this help

The script starts virtiofsd in the background and cleans it up on exit.
Networking uses QEMU user-mode (SLIRP): guest gets 10.0.2.x via NAT.
SSH is forwarded to localhost:2222 by default. Rootfs needs DHCP configured
(see quick-start above). Serial console: -nographic. Press Ctrl-A X to exit.
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
        /usr/lib/qemu/virtiofsd
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
use_net=true
ssh_port=2222
dax_enabled=false
dax_size="256M"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -k|--kernel)  kernel="$2"; shift 2 ;;
        -i|--initrd)  initrd="$2"; shift 2 ;;
        -r|--rootfs)  rootfs="$2"; shift 2 ;;
        -m|--memory)  memory="$2"; shift 2 ;;
        --dax)
            dax_enabled=true
            dax_size="256M"
            if [[ "${2:-}" =~ ^[0-9]+[MmGg]$ ]]; then
                dax_size="$2"
                shift
            fi
            shift
            ;;
        --no-kvm)     use_kvm=false; shift ;;
        --no-net)     use_net=false; shift ;;
        --ssh-port)   ssh_port="$2"; shift 2 ;;
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

# virtiofsd creates the socket and QEMU connects to it. Both must run
# as the same user or the socket permissions won't match. If the rootfs
# is owned by root (e.g., from debootstrap), virtiofsd needs root too.
if [[ "$(stat -c %u "$rootfs")" == "0" && "$(id -u)" != "0" ]]; then
    warn "Rootfs is owned by root. You may need to run this script with sudo."
fi

# ─── Start virtiofsd ──────────────────────────────────────────────

SOCKET_PATH="/tmp/tenkei-vfs-$$.sock"

info "Starting virtiofsd..."
info "  Socket: ${SOCKET_PATH}"
info "  Rootfs: ${rootfs}"

"$virtiofsd_bin" \
    --socket-path="$SOCKET_PATH" \
    --shared-dir="$rootfs" \
    --cache="$( [[ "$dax_enabled" == "true" ]] && echo always || echo auto )" &
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

net_args=""
if [[ "$use_net" == "true" ]]; then
    net_args="-netdev user,id=net0,hostfwd=tcp:127.0.0.1:${ssh_port}-:22"
    net_args+=" -device virtio-net-pci,netdev=net0"
fi

info "Launching QEMU..."
info "  Kernel:  ${kernel}"
info "  Initrd:  ${initrd}"
info "  Memory:  ${memory}M"
info "  KVM:     ${use_kvm}"
if [[ "$dax_enabled" == "true" ]]; then
    info "  DAX:     enabled (cache-size=${dax_size})"
fi
if [[ "$use_net" == "true" ]]; then
    info "  Network: user-mode (SLIRP), guest 10.0.2.x"
    info "  SSH:     ssh -p ${ssh_port} root@127.0.0.1"
else
    info "  Network: disabled"
fi
info ""
info "Press Ctrl-A X to exit QEMU."
info ""

# shellcheck disable=SC2086
qemu-system-x86_64 \
    -machine q35 \
    -kernel "$kernel" \
    -initrd "$initrd" \
    -m "$memory" \
    ${kvm_args} \
    ${net_args} \
    -nographic \
    -chardev "socket,id=vfs,path=${SOCKET_PATH}" \
    -device "vhost-user-fs-pci,chardev=vfs,tag=rootfs$( [[ "$dax_enabled" == "true" ]] && echo ",cache-size=${dax_size}" )" \
    -object "memory-backend-memfd,id=mem,size=${memory}M,share=on" \
    -numa "node,memdev=mem" \
    -append "console=ttyS0 rootfstype=virtiofs root=rootfs"
