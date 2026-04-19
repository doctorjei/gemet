#!/usr/bin/env bash
#
# build-yggdrasil-disk — Build a bootable qcow2 disk image for Yggdrasil
#
# Produces a qcow2 containing a single ext4 filesystem populated from either
# an existing OCI image (yggdrasil:<ver>) or a .tar.xz tarball produced by
# rootfs/build-yggdrasil.sh. No partition table, no bootloader, no /boot —
# the image is intended to be booted externally via tenkei's kernel +
# initramfs using the block-device branch in initramfs/init:
#
#     qemu-system-x86_64 ... \
#         -kernel build/vmlinuz \
#         -initrd build/tenkei-initramfs.img \
#         -drive file=build/yggdrasil-<ver>.qcow2,format=qcow2,if=virtio \
#         -append "console=ttyS0 root=/dev/vda rootfstype=ext4"
#
# NOTE: this script writes mkfs.ext4 directly to the raw backing file (no
# partition table). The guest sees the ext4 fs at /dev/vda, not /dev/vda1.
# Pass `root=/dev/vda rootfstype=ext4` on the kernel cmdline. A partition
# table would only be useful with a bootloader, and we have none.
#
# Usage:
#   build-yggdrasil-disk.sh [--from-oci <tag>]   (default, version from VERSION)
#   build-yggdrasil-disk.sh [--from-txz <path>]
#   build-yggdrasil-disk.sh [--size <GB>]        (default: 2; Yggdrasil ~400 MB)
#   build-yggdrasil-disk.sh [--output <path>]    (default: build/yggdrasil-<ver>.qcow2)
#
# Requires: root (mount, mkfs.ext4, losetup), qemu-img, mkfs.ext4, tar,
# and — for --from-oci — podman or docker.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Helpers ──────────────────────────────────────────────────────
info()  { echo -e "\033[1;34m>>>\033[0m $*"; }
warn()  { echo -e "\033[1;33mWARN:\033[0m $*" >&2; }
error() { echo -e "\033[1;31mERROR:\033[0m $*" >&2; exit 1; }

# ─── Defaults ─────────────────────────────────────────────────────
BUILD_DIR="$REPO_ROOT/build"
VERSION_FILE="$REPO_ROOT/VERSION"

FROM_OCI=""
FROM_TXZ=""
SIZE_GB=2
OUTPUT=""

if [[ ! -f "$VERSION_FILE" ]]; then
    error "VERSION file not found: $VERSION_FILE"
fi
VERSION=$(tr -d '[:space:]' < "$VERSION_FILE")
if [[ -z "$VERSION" ]]; then
    error "VERSION file is empty"
fi

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Build a bootable qcow2 disk image (partition-less, single ext4 fs, no
bootloader) from either the Yggdrasil OCI image or a .tar.xz tarball.

Options:
      --from-oci <tag>   Source the rootfs from an OCI image tag
                         (default: yggdrasil:$VERSION)
      --from-txz <path>  Source the rootfs from a .tar.xz tarball
                         (produced by rootfs/build-yggdrasil.sh)
      --size <GB>        Disk image size in GiB (default: 2)
      --output <path>    Output qcow2 path
                         (default: $BUILD_DIR/yggdrasil-$VERSION.qcow2)
  -h, --help             Show help

--from-oci and --from-txz are mutually exclusive. If neither is given,
--from-oci yggdrasil:$VERSION is used.

Boot contract (partition-less — the whole disk is one ext4 fs):

    qemu-system-x86_64 ... \\
        -kernel build/vmlinuz \\
        -initrd build/tenkei-initramfs.img \\
        -drive file=<output>,format=qcow2,if=virtio \\
        -append "console=ttyS0 root=/dev/vda rootfstype=ext4"

Note the cmdline uses root=/dev/vda (not /dev/vda1) because there's no
partition table. tenkei's initramfs dispatches on root= (see
initramfs/init).

Requires: root (losetup, mount, mkfs.ext4), qemu-img, mkfs.ext4, tar,
and — for --from-oci — podman or docker.
EOF
}

# ─── Parse arguments ──────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --from-oci)  FROM_OCI="$2"; shift 2 ;;
        --from-txz)  FROM_TXZ="$2"; shift 2 ;;
        --size)      SIZE_GB="$2"; shift 2 ;;
        --output)    OUTPUT="$2"; shift 2 ;;
        -h|--help)   usage; exit 0 ;;
        -*)          echo "Error: unknown option: $1" >&2; usage >&2; exit 1 ;;
        *)           echo "Error: unexpected argument: $1" >&2; usage >&2; exit 1 ;;
    esac
done

# ─── Resolve defaults + validate ──────────────────────────────────
if [[ -n "$FROM_OCI" && -n "$FROM_TXZ" ]]; then
    error "--from-oci and --from-txz are mutually exclusive"
fi
if [[ -z "$FROM_OCI" && -z "$FROM_TXZ" ]]; then
    FROM_OCI="yggdrasil:$VERSION"
fi

if [[ -z "$OUTPUT" ]]; then
    OUTPUT="$BUILD_DIR/yggdrasil-${VERSION}.qcow2"
fi

if [[ ! "$SIZE_GB" =~ ^[0-9]+$ ]] || [[ "$SIZE_GB" -lt 1 ]]; then
    error "--size must be a positive integer number of GiB (got: $SIZE_GB)"
fi

# ─── Prerequisites ────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    error "must run as root (for losetup, mount, mkfs.ext4)"
fi

command -v qemu-img  &>/dev/null || error "qemu-img not found (apt install qemu-utils)"
command -v mkfs.ext4 &>/dev/null || error "mkfs.ext4 not found (apt install e2fsprogs)"
command -v losetup   &>/dev/null || error "losetup not found (apt install util-linux)"
command -v tar       &>/dev/null || error "tar not found"

CONTAINER_CMD=""
if [[ -n "$FROM_OCI" ]]; then
    if command -v podman &>/dev/null; then
        CONTAINER_CMD=podman
    elif command -v docker &>/dev/null; then
        CONTAINER_CMD=docker
    else
        error "neither podman nor docker found (needed for --from-oci)"
    fi

    $CONTAINER_CMD image inspect "$FROM_OCI" &>/dev/null || \
        error "OCI image '$FROM_OCI' not found locally. Build it first: sudo bash rootfs/build-yggdrasil.sh"
fi

if [[ -n "$FROM_TXZ" ]]; then
    [[ -f "$FROM_TXZ" ]] || error "tarball not found: $FROM_TXZ"
fi

mkdir -p "$BUILD_DIR"

# ─── Cleanup ──────────────────────────────────────────────────────
TMP_ROOTFS=""
TMP_RAW=""
TMP_MNT=""
LOOP_DEV=""
TEMP_CONTAINER=""

cleanup() {
    if [[ -n "$TMP_MNT" ]] && mountpoint -q "$TMP_MNT" 2>/dev/null; then
        umount "$TMP_MNT" 2>/dev/null || true
    fi
    if [[ -n "$LOOP_DEV" ]]; then
        losetup -d "$LOOP_DEV" 2>/dev/null || true
    fi
    if [[ -n "$TEMP_CONTAINER" && -n "$CONTAINER_CMD" ]]; then
        $CONTAINER_CMD rm "$TEMP_CONTAINER" &>/dev/null || true
    fi
    if [[ -n "$TMP_MNT" && -d "$TMP_MNT" ]]; then
        rmdir "$TMP_MNT" 2>/dev/null || true
    fi
    if [[ -n "$TMP_ROOTFS" && -d "$TMP_ROOTFS" ]]; then
        rm -rf "$TMP_ROOTFS"
    fi
    if [[ -n "$TMP_RAW" && -f "$TMP_RAW" ]]; then
        rm -f "$TMP_RAW"
    fi
}
trap cleanup EXIT

# ─── Extract rootfs ───────────────────────────────────────────────
TMP_ROOTFS=$(mktemp -d "/tmp/yggdrasil-disk-rootfs.XXXXXX")

if [[ -n "$FROM_OCI" ]]; then
    info "Extracting rootfs from OCI image '$FROM_OCI'..."
    TEMP_CONTAINER="yggdrasil-disk-export-$$"
    $CONTAINER_CMD create --name "$TEMP_CONTAINER" "$FROM_OCI" /bin/true >/dev/null
    $CONTAINER_CMD export "$TEMP_CONTAINER" | tar -x -C "$TMP_ROOTFS"
    $CONTAINER_CMD rm "$TEMP_CONTAINER" >/dev/null
    TEMP_CONTAINER=""
else
    info "Extracting rootfs from tarball '$FROM_TXZ'..."
    tar -xJf "$FROM_TXZ" -C "$TMP_ROOTFS"
fi

ROOTFS_BYTES=$(du -sb "$TMP_ROOTFS" | awk '{print $1}')
info "Staged rootfs size: $(du -sh "$TMP_ROOTFS" | awk '{print $1}')"

# ─── Create raw disk image ────────────────────────────────────────
TMP_RAW=$(mktemp "/tmp/yggdrasil-disk.XXXXXX.raw")
SIZE_BYTES=$((SIZE_GB * 1024 * 1024 * 1024))

if [[ "$ROOTFS_BYTES" -ge "$SIZE_BYTES" ]]; then
    error "rootfs ($(du -sh "$TMP_ROOTFS" | awk '{print $1}')) is larger than requested disk size (${SIZE_GB}G). Bump --size."
fi

info "Creating raw disk image (${SIZE_GB}G) at $TMP_RAW..."
qemu-img create -f raw "$TMP_RAW" "${SIZE_GB}G" >/dev/null

# ─── Format ext4 directly on the file (no partition table) ───────
# lazy_*_init=0 forces early init so the image is deterministic rather
# than carrying "finish me on first mount" state.
info "Formatting ext4 on raw image (label=yggdrasil, no partition table)..."
mkfs.ext4 -F -L yggdrasil \
    -E lazy_itable_init=0,lazy_journal_init=0 \
    "$TMP_RAW" >/dev/null

# ─── Loopback-mount and populate ──────────────────────────────────
TMP_MNT=$(mktemp -d "/tmp/yggdrasil-disk-mnt.XXXXXX")

info "Attaching loop device..."
LOOP_DEV=$(losetup -f --show "$TMP_RAW")
info "  Loop:  $LOOP_DEV"

info "Mounting $LOOP_DEV at $TMP_MNT..."
mount "$LOOP_DEV" "$TMP_MNT"

info "Copying rootfs into image..."
cp -a "$TMP_ROOTFS/." "$TMP_MNT/"

info "Syncing + unmounting..."
sync
umount "$TMP_MNT"
TMP_MNT_ORIG="$TMP_MNT"
TMP_MNT=""  # cleanup no longer needs to umount
rmdir "$TMP_MNT_ORIG" 2>/dev/null || true

losetup -d "$LOOP_DEV"
LOOP_DEV=""

# ─── Convert raw → compressed qcow2 ───────────────────────────────
info "Converting raw → compressed qcow2 at $OUTPUT..."
qemu-img convert -c -f raw -O qcow2 "$TMP_RAW" "$OUTPUT"

rm -f "$TMP_RAW"
TMP_RAW=""

# ─── Summary ──────────────────────────────────────────────────────
echo ""
info "yggdrasil disk image built successfully."
echo "  Source:   ${FROM_OCI:-$FROM_TXZ}"
echo "  Output:   $OUTPUT"
echo "  Size:     $(du -h "$OUTPUT" | awk '{print $1}') (qcow2, compressed; ${SIZE_GB}G virtual)"
echo ""
echo "Boot with:"
echo "  qemu-system-x86_64 \\"
echo "      -kernel build/vmlinuz \\"
echo "      -initrd build/tenkei-initramfs.img \\"
echo "      -drive file=$OUTPUT,format=qcow2,if=virtio \\"
echo "      -append \"console=ttyS0 root=/dev/vda rootfstype=ext4\""
echo ""
echo "Or use scripts/test-yggdrasil-disk.sh for a quick smoke test."
