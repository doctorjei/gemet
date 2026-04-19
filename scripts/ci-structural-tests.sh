#!/usr/bin/env bash
#
# ci-structural-tests — Tier 1 (structural) release-artifact checks
#
# Runs unprivileged structural tests against a tenkei build/ directory
# (vmlinuz, initramfs, yggdrasil tarball/qcow2, OCI archives). Designed
# to run on a vanilla ubuntu-24.04 GitHub runner with no KVM, no root,
# no podman. All OCI inspection goes through scripts/extract-oci.sh
# (pure-shell extractor, already in the repo).
#
# Usage:
#   ci-structural-tests.sh [--build-dir DIR] [--version VER] [-h|--help]
#
# Options:
#   --build-dir DIR    Directory containing build artifacts (default: ./build)
#   --version VER      Expected version string (default: read from ./VERSION)
#   -h, --help         Show this help
#
# Exit codes:
#   0   All checks passed
#   1   One or more checks failed
#   2   Usage error / missing prerequisite
#
# Note for local runs: the *-oci.tar files produced by `podman save` under
# sudo are sometimes root-owned. This script reads them as unprivileged
# (extract-oci.sh untars into a scratch dir), so as long as they are
# world-readable (chmod 644 *-oci.tar) this runs fine without sudo.
#
set -euo pipefail

# ─── Helpers ──────────────────────────────────────────────────────
info()  { echo -e "\033[1;34m>>>\033[0m $*"; }
warn()  { echo -e "\033[1;33mWARN:\033[0m $*" >&2; }
error() { echo -e "\033[1;31mERROR:\033[0m $*" >&2; exit 2; }

pass()  { echo -e "\033[1;32m[PASS]\033[0m $*"; PASSED=$((PASSED + 1)); }
fail()  { echo -e "\033[1;31m[FAIL]\033[0m $*" >&2; FAILED=$((FAILED + 1)); }

usage() {
    cat <<'USAGE'
Usage: ci-structural-tests.sh [--build-dir DIR] [--version VER] [-h|--help]

Run Tier 1 (structural) release-candidate checks against a build/ dir.

Options:
  --build-dir DIR    Directory containing build artifacts (default: ./build)
  --version VER      Expected version string (default: read from ./VERSION)
  -h, --help         Show this help

Exit codes:
  0  all checks passed
  1  one or more checks failed
  2  usage error / missing prerequisite
USAGE
}

# ─── Parse arguments ──────────────────────────────────────────────
BUILD_DIR="./build"
VERSION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --build-dir)   BUILD_DIR="$2"; shift 2 ;;
        --build-dir=*) BUILD_DIR="${1#*=}"; shift ;;
        --version)     VERSION="$2"; shift 2 ;;
        --version=*)   VERSION="${1#*=}"; shift ;;
        -h|--help)     usage; exit 0 ;;
        *)             echo "Error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ -d "$BUILD_DIR" ]] || error "build dir not found: $BUILD_DIR"

# Resolve to an absolute path so later operations are cwd-agnostic.
BUILD_DIR=$(cd "$BUILD_DIR" && pwd)

if [[ -z "$VERSION" ]]; then
    if [[ -f "./VERSION" ]]; then
        VERSION=$(tr -d '[:space:]' < ./VERSION)
    else
        error "no --version given and ./VERSION not found"
    fi
fi

# ─── Locate helpers ───────────────────────────────────────────────
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
EXTRACT_OCI="$SCRIPT_DIR/extract-oci.sh"
[[ -x "$EXTRACT_OCI" ]] || error "missing or non-executable: $EXTRACT_OCI"

# ─── Prerequisites ────────────────────────────────────────────────
for tool in tar jq file cpio xz qemu-img gunzip; do
    command -v "$tool" >/dev/null 2>&1 || \
        error "missing required tool: $tool"
done

# ─── Cleanup ──────────────────────────────────────────────────────
SCRATCH=""
cleanup() {
    [[ -n "$SCRATCH" && -d "$SCRATCH" ]] && rm -rf "$SCRATCH" 2>/dev/null || true
}
trap cleanup EXIT

SCRATCH=$(mktemp -d "/tmp/ci-structural.XXXXXX")

PASSED=0
FAILED=0

info "Build dir: $BUILD_DIR"
info "Expected version: $VERSION"
echo ""

# ─── Check 1: VERSION file matches --version arg ──────────────────
info "Check 1: VERSION file matches expected version"
if [[ -f "./VERSION" ]]; then
    file_ver=$(tr -d '[:space:]' < ./VERSION)
    if [[ "$file_ver" == "$VERSION" ]]; then
        pass "VERSION file == $VERSION"
    else
        fail "VERSION file '$file_ver' != expected '$VERSION'"
    fi
else
    fail "./VERSION file not found"
fi
echo ""

# ─── Check 2: vmlinuz ─────────────────────────────────────────────
info "Check 2: vmlinuz"
VMLINUZ="$BUILD_DIR/vmlinuz"
if [[ ! -f "$VMLINUZ" ]]; then
    fail "vmlinuz not found at $VMLINUZ"
elif [[ ! -s "$VMLINUZ" ]]; then
    fail "vmlinuz is zero-length: $VMLINUZ"
else
    file_out=$(file -b "$VMLINUZ" || true)
    if [[ "$file_out" == *"Linux kernel"* ]]; then
        pass "vmlinuz exists, non-zero, bzImage magic ($(du -h "$VMLINUZ" | awk '{print $1}'))"
    else
        fail "vmlinuz does not look like a Linux kernel: $file_out"
    fi
fi
echo ""

# ─── Check 3: tenkei-initramfs.img ────────────────────────────────
info "Check 3: tenkei-initramfs.img"
INITRAMFS="$BUILD_DIR/tenkei-initramfs.img"
if [[ ! -f "$INITRAMFS" ]]; then
    fail "initramfs not found at $INITRAMFS"
elif [[ ! -s "$INITRAMFS" ]]; then
    fail "initramfs is zero-length: $INITRAMFS"
else
    file_out=$(file -b "$INITRAMFS" || true)
    if [[ "$file_out" != *"gzip compressed"* ]]; then
        fail "initramfs is not gzip-compressed: $file_out"
    else
        # Extract to scratch and look for /init + /bin/busybox.
        INITRAMFS_DIR="$SCRATCH/initramfs"
        mkdir -p "$INITRAMFS_DIR"
        if ! ( cd "$INITRAMFS_DIR" && gunzip -c "$INITRAMFS" | cpio -idm --quiet ) 2>/dev/null; then
            fail "initramfs could not be extracted as gzip+cpio"
        else
            missing=""
            for f in init bin/busybox; do
                if [[ ! -f "$INITRAMFS_DIR/$f" ]]; then
                    missing+=" /$f"
                elif [[ ! -x "$INITRAMFS_DIR/$f" ]]; then
                    missing+=" /$f(not-executable)"
                fi
            done
            if [[ -n "$missing" ]]; then
                fail "initramfs missing/non-executable entries:$missing"
            else
                pass "initramfs exists, gzip+cpio, contains executable /init and /bin/busybox"
            fi
        fi
    fi
fi
echo ""

# ─── Check 4: yggdrasil-<ver>.tar.xz ──────────────────────────────
info "Check 4: yggdrasil-${VERSION}.tar.xz"
TARXZ="$BUILD_DIR/yggdrasil-${VERSION}.tar.xz"
if [[ ! -f "$TARXZ" ]]; then
    fail "tarball not found at $TARXZ"
elif [[ ! -s "$TARXZ" ]]; then
    fail "tarball is zero-length: $TARXZ"
else
    if ! tar -tJf "$TARXZ" >/dev/null 2>&1; then
        fail "tar -tJf failed — archive is corrupt or not a tar.xz"
    else
        # Read uncompressed size via xz --robot (machine-readable).
        uncompressed=$(xz -l --robot "$TARXZ" 2>/dev/null \
            | awk '$1=="totals"{print $5}')
        if [[ -z "$uncompressed" || ! "$uncompressed" =~ ^[0-9]+$ ]]; then
            fail "could not read uncompressed size from xz -l"
        else
            MB=$((uncompressed / 1024 / 1024))
            if (( MB >= 200 && MB <= 280 )); then
                pass "tar.xz OK, uncompressed ${MB} MB (within 200-280 MB)"
            else
                fail "uncompressed size ${MB} MB outside 200-280 MB bounds"
            fi
        fi
    fi
fi
echo ""

# ─── Check 5: yggdrasil-<ver>.qcow2 ───────────────────────────────
info "Check 5: yggdrasil-${VERSION}.qcow2"
QCOW2="$BUILD_DIR/yggdrasil-${VERSION}.qcow2"
if [[ ! -f "$QCOW2" ]]; then
    fail "qcow2 not found at $QCOW2"
elif [[ ! -s "$QCOW2" ]]; then
    fail "qcow2 is zero-length: $QCOW2"
else
    if qemu-img info "$QCOW2" >/dev/null 2>&1; then
        pass "qcow2 OK ($(du -h "$QCOW2" | awk '{print $1}'))"
    else
        fail "qemu-img info rejected $QCOW2"
    fi
fi
echo ""

# ─── Check 6: yggdrasil-<ver>-oci.tar ─────────────────────────────
info "Check 6: yggdrasil-${VERSION}-oci.tar"
YGG_OCI="$BUILD_DIR/yggdrasil-${VERSION}-oci.tar"
if [[ ! -f "$YGG_OCI" ]]; then
    fail "yggdrasil OCI archive not found at $YGG_OCI"
elif [[ ! -s "$YGG_OCI" ]]; then
    fail "yggdrasil OCI archive is zero-length: $YGG_OCI"
else
    YGG_ROOT="$SCRATCH/yggdrasil-rootfs"
    if ! "$EXTRACT_OCI" --dir "$YGG_OCI" "$YGG_ROOT" >/dev/null 2>&1; then
        fail "extract-oci.sh --dir failed on $YGG_OCI"
    else
        bad=""
        # /sbin/init (symlink OR regular file)
        if [[ ! -e "$YGG_ROOT/sbin/init" && ! -L "$YGG_ROOT/sbin/init" ]]; then
            bad+=" missing:/sbin/init"
        fi
        # /usr/bin/python3 (symlink OR regular file)
        if [[ ! -e "$YGG_ROOT/usr/bin/python3" && ! -L "$YGG_ROOT/usr/bin/python3" ]]; then
            bad+=" missing:/usr/bin/python3"
        fi
        # /etc/systemd/system/ populated (>= 5 entries)
        if [[ ! -d "$YGG_ROOT/etc/systemd/system" ]]; then
            bad+=" missing:/etc/systemd/system"
        else
            entries=$(find "$YGG_ROOT/etc/systemd/system" -mindepth 1 -maxdepth 1 | wc -l)
            if (( entries < 5 )); then
                bad+=" /etc/systemd/system-only-${entries}-entries"
            fi
        fi
        # /var/lib/dpkg/status parseable, >= 50 Package: lines, no half-installed
        DPKG_STATUS="$YGG_ROOT/var/lib/dpkg/status"
        if [[ ! -f "$DPKG_STATUS" ]]; then
            bad+=" missing:/var/lib/dpkg/status"
        else
            pkgs=$(grep -c '^Package:' "$DPKG_STATUS" 2>/dev/null || echo 0)
            if (( pkgs < 50 )); then
                bad+=" dpkg-status-only-${pkgs}-packages"
            fi
            # Any Status line that is not "install ok installed"?
            bad_statuses=$(awk '/^Status:/ && $0 != "Status: install ok installed"' \
                "$DPKG_STATUS" | head -5 || true)
            if [[ -n "$bad_statuses" ]]; then
                bad+=" half-installed-pkgs"
                warn "half-installed packages (first few):"
                awk '/^Package:/{p=$2} /^Status:/ && $0 != "Status: install ok installed"{print "    "p" -> "$0}' \
                    "$DPKG_STATUS" | head -10 >&2 || true
            fi
        fi

        if [[ -z "$bad" ]]; then
            pass "yggdrasil OCI structure OK (init, python3, systemd units, dpkg clean: $pkgs pkgs)"
        else
            fail "yggdrasil OCI issues:$bad"
        fi
    fi
fi
echo ""

# ─── Check 7: tenkei-kernel-<ver>-oci.tar ─────────────────────────
info "Check 7: tenkei-kernel-${VERSION}-oci.tar"
KERN_OCI="$BUILD_DIR/tenkei-kernel-${VERSION}-oci.tar"
if [[ ! -f "$KERN_OCI" ]]; then
    fail "kernel OCI archive not found at $KERN_OCI"
elif [[ ! -s "$KERN_OCI" ]]; then
    fail "kernel OCI archive is zero-length: $KERN_OCI"
else
    KERN_ROOT="$SCRATCH/kernel-rootfs"
    if ! "$EXTRACT_OCI" --dir "$KERN_OCI" "$KERN_ROOT" >/dev/null 2>&1; then
        fail "extract-oci.sh --dir failed on $KERN_OCI"
    else
        bad=""
        for f in boot/vmlinuz boot/initramfs.img; do
            if [[ ! -f "$KERN_ROOT/$f" ]]; then
                bad+=" missing:/$f"
            elif [[ ! -s "$KERN_ROOT/$f" ]]; then
                bad+=" zero-length:/$f"
            fi
        done
        if [[ -z "$bad" ]]; then
            pass "kernel OCI contains non-empty /boot/vmlinuz and /boot/initramfs.img"
        else
            fail "kernel OCI issues:$bad"
        fi
    fi
fi
echo ""

# ─── Summary ──────────────────────────────────────────────────────
TOTAL=$((PASSED + FAILED))
echo "─────────────────────────────────────────────"
if (( FAILED == 0 )); then
    echo -e "\033[1;32m${PASSED} passed, ${FAILED} failed\033[0m (of $TOTAL checks)"
    exit 0
else
    echo -e "\033[1;31m${PASSED} passed, ${FAILED} failed\033[0m (of $TOTAL checks)"
    exit 1
fi
