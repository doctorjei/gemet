#!/usr/bin/env bash
#
# build-yggdrasil — Build the Yggdrasil OCI base image from Debian 13 genericcloud
#
# Downloads the Debian 13 genericcloud qcow2, extracts the rootfs via qemu-nbd,
# purges kernel/boot packages and a short Yggdrasil-specific drop list (cloud-init,
# polkit, resolved/timesyncd, apparmor, dmsetup, ...), stages networkd config and
# the SSH-key sync service, and imports the result as an OCI image.
#
# Yggdrasil is tenkei's minimal Debian 13 + systemd foundation. Downstream
# consumers (droste tiers, etc.) compose it via Containerfile `FROM yggdrasil:<ver>`.
#
# Usage:
#   build-yggdrasil.sh
#   build-yggdrasil.sh --no-import    # Build rootfs only, skip container import
#   build-yggdrasil.sh --no-txz       # Skip the .tar.xz tarball artifact
#
# Produces (by default):
#   - OCI image  yggdrasil:<version>               (via --import, on by default)
#   - Tarball    build/yggdrasil-<version>.tar.xz  (raw rootfs, for lxc-create etc.)
#
# --no-import and --no-txz are independent; pass either or both to drop the
# corresponding artifact. At least the rootfs is still staged in a temp dir
# during the run (cleaned on exit).
#
# Requires: root (for qemu-nbd, mount, chroot), podman or docker (for import).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Defaults ────────────────────────────────────────────────────────
BUILD_DIR="$REPO_ROOT/build"
DOWNLOAD_DIR="$BUILD_DIR/download"
SEED_TARGET="$REPO_ROOT/rootfs/seed-target.txt"
NETWORKD_CONF="$REPO_ROOT/rootfs/networkd/80-dhcp.network"
SSHKEY_UNIT="$REPO_ROOT/rootfs/sshkey/yggdrasil-sshkey-sync.service"
SSHKEY_SCRIPT="$REPO_ROOT/rootfs/sshkey/sync-sshkeys.sh"
VERSION_FILE="$REPO_ROOT/VERSION"
DO_IMPORT=true
DO_TXZ=true

QCOW2_URL="https://cloud.debian.org/images/cloud/trixie/latest"
QCOW2_FILE="debian-13-genericcloud-amd64.qcow2"
# NBD_DEV is set later by find_free_nbd (after modprobe nbd)

# ── Helpers (match scripts/git-upstream.sh style) ───────────────────
info() { echo -e "\033[1;34m>>>\033[0m $*"; }
warn() { echo -e "\033[1;33mWARN:\033[0m $*" >&2; }
error() { echo -e "\033[1;31mERROR:\033[0m $*" >&2; exit 1; }

# ── Version ─────────────────────────────────────────────────────────
if [[ ! -f "$VERSION_FILE" ]]; then
    error "VERSION file not found: $VERSION_FILE"
fi
VERSION=$(tr -d '[:space:]' < "$VERSION_FILE")
if [[ -z "$VERSION" ]]; then
    error "VERSION file is empty"
fi
IMAGE_TAG="yggdrasil:$VERSION"

# Phase 1 purge: kernel, bootloader, UEFI, container-irrelevant.
# (Droste's list minus `busybox` — we keep busybox in Yggdrasil.)
PURGE_PACKAGES=(
    cloud-initramfs-growroot
    dracut-install
    grub-cloud-amd64
    grub-common
    grub-efi-amd64-bin
    grub-efi-amd64-signed
    grub-efi-amd64-unsigned
    grub-pc-bin
    grub2-common
    libefiboot1t64
    libefivar1t64
    libfreetype6
    libnetplan1
    libpng16-16t64
    linux-image-cloud-amd64
    linux-sysctl-defaults
    mokutil
    netplan-generator
    netplan.io
    os-prober
    pci.ids
    pciutils
    python3-netplan
    shim-helpers-amd64-signed
    shim-signed
    shim-signed-common
    shim-unsigned
)

# Yggdrasil-specific strip: drops beyond the Phase 1 kernel/boot purge.
# See ~/playbook/plans/yggdrasil.md for the rationale on each entry.
YGGDRASIL_STRIP_PACKAGES=(
    cloud-init
    cloud-guest-utils
    cloud-image-utils
    cloud-utils
    polkitd
    libpolkit-agent-1-0
    libpolkit-gobject-1-0
    systemd-resolved
    systemd-timesyncd
    unattended-upgrades
    dmsetup
    apparmor
    screen
    qemu-utils
    dosfstools
    gdisk
    genisoimage
    dhcpcd-base
    reportbug
    python3-reportbug
    python3-debianbts
    apt-listchanges
    ssh-import-id
    bind9-host
    bind9-libs
    vim
    vim-common
    vim-runtime
)

# ── Usage ───────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Build the Yggdrasil OCI base image from the Debian 13 genericcloud qcow2.

Downloads the image, extracts the rootfs, purges kernel/boot packages plus a
Yggdrasil-specific drop list, stages networkd config + the ssh-key sync service,
and imports the result as OCI image '$IMAGE_TAG'.

Options:
      --no-import      Skip container import (OCI image not produced)
      --no-txz         Skip .tar.xz tarball output
  -h, --help           Show help

Requires: root (for qemu-nbd, mount, chroot), podman or docker (for import).

Downloads are cached in $DOWNLOAD_DIR to avoid redundant fetches.
EOF
}

# ── Parse arguments ─────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-import)     DO_IMPORT=false; shift ;;
        --no-txz)        DO_TXZ=false; shift ;;
        -h|--help)       usage; exit 0 ;;
        -*)              echo "Error: unknown option: $1" >&2; usage >&2; exit 1 ;;
        *)               echo "Error: unexpected argument: $1" >&2; usage >&2; exit 1 ;;
    esac
done

# ── Prerequisites ───────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    error "must run as root (for qemu-nbd, mount, chroot)"
fi

if [[ ! -f "$SEED_TARGET" ]]; then
    error "seed target list not found: $SEED_TARGET"
fi

if [[ ! -f "$NETWORKD_CONF" ]]; then
    error "networkd config not found: $NETWORKD_CONF"
fi

detect_container_cmd() {
    if command -v podman &>/dev/null; then
        echo podman
    elif command -v docker &>/dev/null; then
        echo docker
    else
        error "neither podman nor docker found"
    fi
}

find_free_nbd() {
    for dev in /sys/block/nbd*; do
        if [[ "$(cat "$dev/size" 2>/dev/null)" == "0" ]]; then
            echo "/dev/${dev##*/}"
            return 0
        fi
    done
    error "no free nbd device found"
}

if $DO_IMPORT; then
    CONTAINER_CMD=$(detect_container_cmd)
fi

# ── Cleanup helpers ─────────────────────────────────────────────────
cleanup_mounts() {
    local rootfs="$1"
    mountpoint -q "$rootfs/dev/pts"  2>/dev/null && umount "$rootfs/dev/pts"  || true
    mountpoint -q "$rootfs/dev"      2>/dev/null && umount "$rootfs/dev"      || true
    mountpoint -q "$rootfs/proc"     2>/dev/null && umount "$rootfs/proc"     || true
    mountpoint -q "$rootfs/sys"      2>/dev/null && umount "$rootfs/sys"      || true
}

cleanup_nbd() {
    local mnt="$1"
    mountpoint -q "$mnt" 2>/dev/null && umount "$mnt" || true
    qemu-nbd -d "$NBD_DEV" 2>/dev/null || true
}

cleanup() {
    if [[ -d "${WORK_DIR:-}" ]]; then
        cleanup_mounts "$WORK_DIR"
        rm -rf "$WORK_DIR"
    fi
    if [[ -d "${MNT_DIR:-}" ]]; then
        cleanup_nbd "$MNT_DIR"
        rm -rf "$MNT_DIR"
    fi
}
trap cleanup EXIT

# ── Download and verify qcow2 ──────────────────────────────────────
mkdir -p "$DOWNLOAD_DIR"

CACHED="$DOWNLOAD_DIR/$QCOW2_FILE"
if [[ -f "$CACHED" ]]; then
    info "Using cached download: $CACHED"
else
    info "Downloading $QCOW2_FILE..."
    curl -L --progress-bar -o "$CACHED.tmp" "$QCOW2_URL/$QCOW2_FILE"
    mv "$CACHED.tmp" "$CACHED"
fi

info "Verifying SHA512..."
EXPECTED_SHA=$(curl -sL "$QCOW2_URL/SHA512SUMS" \
    | grep "$QCOW2_FILE" | awk '{print $1}')
if [[ -z "$EXPECTED_SHA" ]]; then
    warn "could not fetch SHA512 checksum, skipping verification"
else
    ACTUAL_SHA=$(sha512sum "$CACHED" | awk '{print $1}')
    if [[ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]]; then
        echo "  expected: $EXPECTED_SHA" >&2
        echo "  actual:   $ACTUAL_SHA" >&2
        rm -f "$CACHED"
        error "SHA512 mismatch"
    fi
    info "SHA512 verified."
fi

# ── Extract rootfs via qemu-nbd ────────────────────────────────────
MNT_DIR=$(mktemp -d "/tmp/yggdrasil-mnt.XXXXXX")
WORK_DIR=$(mktemp -d "/tmp/yggdrasil-rootfs.XXXXXX")

modprobe nbd max_part=8
NBD_DEV=$(find_free_nbd)

info "Connecting qcow2 to $NBD_DEV..."
qemu-nbd -c "$NBD_DEV" "$CACHED" --read-only

partprobe "$NBD_DEV" 2>/dev/null || true
info "Waiting for ${NBD_DEV}p1 to appear..."
waited=0
while ! [[ -b "${NBD_DEV}p1" ]]; do
    sleep 0.5
    waited=$((waited + 1))
    if [[ $waited -ge 20 ]]; then
        error "${NBD_DEV}p1 did not appear after 10 seconds"
    fi
done
info "Partition appeared after $((waited / 2)).$((waited % 2 * 5))s"

# Find root partition — genericcloud uses partition 1 (or 2 if p1 is EFI)
ROOT_PART="${NBD_DEV}p1"
P1_FSTYPE=$(blkid -o value -s TYPE "${NBD_DEV}p1" 2>/dev/null || true)
if [[ "$P1_FSTYPE" == "vfat" ]] && [[ -b "${NBD_DEV}p2" ]]; then
    ROOT_PART="${NBD_DEV}p2"
fi

info "Mounting root partition ($ROOT_PART) at $MNT_DIR..."
mount -o ro "$ROOT_PART" "$MNT_DIR"

info "Copying rootfs..."
cp -a "$MNT_DIR/." "$WORK_DIR/"

info "Disconnecting qcow2..."
cleanup_nbd "$MNT_DIR"

# ── Set up chroot ───────────────────────────────────────────────────
info "Setting up chroot..."
mount --bind /dev "$WORK_DIR/dev"
mount --bind /proc "$WORK_DIR/proc"
mount --bind /sys "$WORK_DIR/sys"
mount -t devpts devpts "$WORK_DIR/dev/pts"

rm -f "$WORK_DIR/etc/resolv.conf"
cp /etc/resolv.conf "$WORK_DIR/etc/resolv.conf"

# Write package lists into chroot
printf '%s\n' "${PURGE_PACKAGES[@]}" > "$WORK_DIR/tmp/purge-list.txt"
printf '%s\n' "${YGGDRASIL_STRIP_PACKAGES[@]}" > "$WORK_DIR/tmp/ygg-strip-list.txt"
grep -v '^#' "$SEED_TARGET" | grep -v '^$' > "$WORK_DIR/tmp/seed-keep.txt"

# ── Strip packages in chroot ────────────────────────────────────────
# The strip script runs inside the chroot. It removes kernel/boot packages
# (PURGE_PACKAGES) and the Yggdrasil-specific drop list (YGGDRASIL_STRIP_PACKAGES),
# then apt-get autoremove to reclaim orphaned deps (e.g. python3-* reportbug deps).
cat > "$WORK_DIR/tmp/strip.sh" <<'STRIP_EOF'
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "Packages before strip: $(dpkg -l | grep '^ii' | wc -l)"

# Prevent services from starting during removal
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d

# Mark all seed target packages as manually installed so autoremove
# won't pull them out when their reverse-deps get purged
echo "Marking seed packages as manually installed..."
xargs apt-mark manual < /tmp/seed-keep.txt 2>/dev/null || true

# Disable grub postrm hook — grub-probe fails in chroot (no root device)
dpkg-divert --local --rename --add /etc/kernel/postrm.d/zz-update-grub 2>/dev/null || true
rm -f /etc/kernel/postrm.d/zz-update-grub

# Filter purge list to only installed packages (avoids "not installed" noise)
filter_installed() {
    local src="$1" dst="$2"
    : > "$dst"
    while read -r pkg; do
        [[ -z "$pkg" ]] && continue
        if dpkg -s "$pkg" &>/dev/null; then
            echo "$pkg" >> "$dst"
        fi
    done < "$src"
}

echo "Filtering purge list to installed packages..."
filter_installed /tmp/purge-list.txt /tmp/purge-installed.txt
filter_installed /tmp/ygg-strip-list.txt /tmp/ygg-strip-installed.txt

# Remove dirs that cause "not empty" warnings during purge
rm -rf /etc/grub.d /etc/default/grub.d /etc/kernel/postrm.d

# Phase 1: purge kernel/boot packages
echo "Purging kernel/boot packages..."
if [[ -s /tmp/purge-installed.txt ]]; then
    xargs apt-get purge -y --allow-remove-essential < /tmp/purge-installed.txt 2>&1 \
        | grep -v 'dpkg: warning: this is a protected package'
fi
apt-get autoremove -y || true

# Phase 2: Yggdrasil-specific strip (cloud-init, polkit, resolved, ...)
# None of these are essential, so --allow-remove-essential isn't required;
# the grep filter is kept for output cleanliness.
#
# Re-filter after the phase-1 autoremove: entries like cloud-image-utils,
# cloud-utils, qemu-utils, genisoimage may already be gone (reaped as orphans
# once their parents were purged). Feeding stale entries to apt-get remove
# exits 100 and — under `set -euo pipefail` — kills the whole script.
filter_installed /tmp/ygg-strip-installed.txt /tmp/ygg-strip-installed.txt.2
mv /tmp/ygg-strip-installed.txt.2 /tmp/ygg-strip-installed.txt

if [[ -s /tmp/ygg-strip-installed.txt ]]; then
    echo "Purging Yggdrasil-specific packages..."
    xargs apt-get remove -y --purge < /tmp/ygg-strip-installed.txt 2>&1 \
        | grep -v 'dpkg: warning: this is a protected package'
fi
apt-get autoremove --purge -y || true

# Install editor fallbacks explicitly, regardless of autoremove outcome.
# vim-tiny provides /usr/bin/vi; nano is the Debian default for $EDITOR.
apt-get update
apt-get install -y --no-install-recommends vim-tiny nano

# Clean apt cache
apt-get clean
rm -rf /var/lib/apt/lists/*

# Remove policy-rc.d
rm -f /usr/sbin/policy-rc.d

echo "Packages after strip: $(dpkg -l | grep '^ii' | wc -l)"
rm -f /tmp/strip.sh /tmp/purge-list.txt /tmp/ygg-strip-list.txt \
      /tmp/seed-keep.txt /tmp/purge-installed.txt /tmp/ygg-strip-installed.txt
STRIP_EOF
chmod +x "$WORK_DIR/tmp/strip.sh"

info "Running package strip in chroot..."
chroot "$WORK_DIR" /tmp/strip.sh

# ── Stage Yggdrasil config + services ───────────────────────────────
info "Staging networkd DHCP config..."
install -D -m 0644 "$NETWORKD_CONF" \
    "$WORK_DIR/etc/systemd/network/80-dhcp.network"

# Yggdrasil SSH key sync service (Phase 3 ships the files). If they don't
# exist yet, stage what we can and warn — Phase 2 remains testable.
SSHKEY_STAGED=false
if [[ -f "$SSHKEY_UNIT" ]] && [[ -f "$SSHKEY_SCRIPT" ]]; then
    info "Staging SSH key sync service + script..."
    install -D -m 0644 "$SSHKEY_UNIT" \
        "$WORK_DIR/etc/systemd/system/yggdrasil-sshkey-sync.service"
    install -D -m 0755 "$SSHKEY_SCRIPT" \
        "$WORK_DIR/usr/local/sbin/sync-sshkeys.sh"
    SSHKEY_STAGED=true
else
    warn "SSH key sync files not found (Phase 3 pending):"
    warn "  $SSHKEY_UNIT"
    warn "  $SSHKEY_SCRIPT"
    warn "Skipping unit enable — Yggdrasil will boot but won't sync authorized_keys."
fi

# Create the /etc/yggdrasil/ directory. Orchestrators drop
# authorized_keys here; the sync service reads it on boot.
install -d -m 0755 "$WORK_DIR/etc/yggdrasil"

# ── Per-image setup inside chroot (locales, unit enables) ──────────
# No droste user, no sysctl ip_forward — both are droste-specific opinions
# that don't belong in Yggdrasil's foundation.
cat > "$WORK_DIR/tmp/setup.sh" <<SETUP_EOF
#!/bin/bash
set -euo pipefail

# Enable systemd-networkd so 80-dhcp.network takes effect on boot
systemctl enable systemd-networkd.service

# Enable SSH key sync service if it was staged
if $SSHKEY_STAGED; then
    systemctl enable yggdrasil-sshkey-sync.service
fi

# Locales — inherit droste's 15 (en_US, zh_CN, zh_TW, hi_IN, es_ES, ar_SA,
# fr_FR, bn_IN, pt_BR, pt_PT, id_ID, ur_PK, de_DE, ja_JP, ko_KR)
sed -i '/^# .*UTF-8/{
    /en_US\|zh_CN\|zh_TW\|hi_IN\|es_ES\|ar_SA\|fr_FR\|bn_IN\|pt_BR\|pt_PT\|id_ID\|ur_PK\|de_DE\|ja_JP\|ko_KR/s/^# //
}' /etc/locale.gen
locale-gen
SETUP_EOF
chmod +x "$WORK_DIR/tmp/setup.sh"

info "Running Yggdrasil per-image setup (locales, unit enables)..."
chroot "$WORK_DIR" /tmp/setup.sh
rm -f "$WORK_DIR/tmp/setup.sh"

# ── Tear down chroot ───────────────────────────────────────────────
info "Cleaning up mounts..."
cleanup_mounts "$WORK_DIR"

# Remove boot artifacts that remain after package purge
rm -rf "$WORK_DIR/boot/"*
rm -rf "$WORK_DIR/lib/modules/"*

# Clear stale fstab from genericcloud (UUID-based mounts for partitions that
# don't exist in containers, and cause boot failures in VM-bootable images)
printf '# Empty — no block devices in OCI base\n' > "$WORK_DIR/etc/fstab"

# ── Produce tarball artifact ────────────────────────────────────────
# Written before the OCI import so both artifacts come from the same
# staged work dir. Independent of --no-import.
TXZ_PATH="$BUILD_DIR/yggdrasil-${VERSION}.tar.xz"
if $DO_TXZ; then
    info "Writing tarball $TXZ_PATH..."
    mkdir -p "$BUILD_DIR"
    tar -cJf "$TXZ_PATH" -C "$WORK_DIR" .
    info "Tarball size: $(du -h "$TXZ_PATH" | awk '{print $1}')"
fi

# ── Import into container engine ────────────────────────────────────
if $DO_IMPORT; then
    info "Importing into $CONTAINER_CMD as $IMAGE_TAG..."
    tar -c -C "$WORK_DIR" . | $CONTAINER_CMD import - "$IMAGE_TAG"
    echo ""
    info "Image imported."
    $CONTAINER_CMD image inspect "$IMAGE_TAG" --format '{{.Size}}' | \
        awk '{printf "Image size: %.0f MB\n", $1/1024/1024}'
fi

# ── Summary ─────────────────────────────────────────────────────────
echo ""
info "yggdrasil built successfully."
echo "  Source:   $QCOW2_FILE (genericcloud)"
echo "  Removed:  ${#PURGE_PACKAGES[@]} kernel/boot + ${#YGGDRASIL_STRIP_PACKAGES[@]} Yggdrasil-specific packages"
if $DO_IMPORT; then
    echo "  Image:    $IMAGE_TAG ($CONTAINER_CMD)"
fi
if $DO_TXZ; then
    echo "  Tarball:  $TXZ_PATH"
fi
