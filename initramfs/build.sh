#!/usr/bin/env bash
#
# build.sh — Build tenkei's initramfs image
#
# Creates a minimal initramfs containing busybox and the tenkei init script.
# The init script mounts a virtiofs share and switch_roots into it.
#
# Usage:
#   build.sh [output-path]
#
# Arguments:
#   output-path   Path for the output image (default: initramfs/gemet-initramfs.img)
#
# Requirements:
#   busybox-static (Debian/Ubuntu: apt install busybox-static)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_OUTPUT="${SCRIPT_DIR}/gemet-initramfs.img"

# ─── Helpers ───────────────────────────────────────────────────────

info()  { echo -e "\033[1;34m>>>\033[0m $*"; }
warn()  { echo -e "\033[1;33mWARN:\033[0m $*" >&2; }
error() { echo -e "\033[1;31mERROR:\033[0m $*" >&2; exit 1; }

cleanup() {
    if [[ -n "${STAGING:-}" && -d "$STAGING" ]]; then
        rm -rf "$STAGING"
    fi
}
trap cleanup EXIT

# ─── Find busybox ─────────────────────────────────────────────────

find_busybox() {
    local candidates=(
        /usr/bin/busybox-static
        /bin/busybox-static
        /usr/bin/busybox
        /bin/busybox
    )
    for path in "${candidates[@]}"; do
        if [[ -x "$path" ]]; then
            # Verify it's statically linked
            if file "$path" | grep -q "statically linked"; then
                echo "$path"
                return
            fi
        fi
    done
    error "busybox-static not found. Install it: apt install busybox-static"
}

# ─── Main ──────────────────────────────────────────────────────────

output="${1:-$DEFAULT_OUTPUT}"
mkdir -p "$(dirname "$output")"
output="$(cd "$(dirname "$output")" && pwd)/$(basename "$output")"

busybox="$(find_busybox)"
info "Using busybox: ${busybox}"

# Create staging directory
STAGING="$(mktemp -d)"
info "Staging in ${STAGING}"

# Create directory structure
mkdir -p "${STAGING}"/{dev,proc,sys,newroot,bin,sbin,usr/bin,usr/sbin}

# Install busybox
cp "$busybox" "${STAGING}/bin/busybox"
chmod +x "${STAGING}/bin/busybox"

# Create symlinks for all busybox applets
(
    cd "$STAGING"
    for applet in $(bin/busybox --list); do
        # Skip busybox itself — don't overwrite the real binary with a symlink
        [[ "$applet" == "busybox" ]] && continue
        # Place common applets in the right directories
        case "$applet" in
            mount|umount|switch_root|pivot_root|mdev)
                ln -sf ../bin/busybox "sbin/${applet}" ;;
            *)
                ln -sf busybox "bin/${applet}" ;;
        esac
    done
)

# Install init script
cp "${SCRIPT_DIR}/init" "${STAGING}/init"
chmod +x "${STAGING}/init"

# Pack as cpio + gzip
info "Packing initramfs..."
(
    cd "$STAGING"
    find . -print0 | cpio --null -H newc -o --quiet | gzip -9
) > "$output"

size=$(du -h "$output" | cut -f1)
info "Built: ${output} (${size})"
