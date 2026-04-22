#!/usr/bin/env bash
#
# build-bifrost — Derived image builder: yggdrasil + opinionated SSH layer
#
# Bifrost is a derived image. This script extracts the Yggdrasil .txz,
# overlays the bifrost policy bits (host-key first-boot generation +
# /etc/bifrost/authorized_keys sync machinery + sshd enabled), and
# re-packages as .txz / qcow2 / OCI.
#
# No podman build. No chroot. The overlay is a handful of file installs
# and symlink creations — identical to what `systemctl enable` would do,
# but executed via plain `ln -s` so it works inside an unprivileged user
# namespace (no dbus, no running systemd).
#
# Preconditions:
#   - build/yggdrasil-<VERSION>.txz must exist (from `rootfs/build-yggdrasil.sh`)
#
# Usage:
#   build-bifrost.sh                         # build everything (reads VERSION)
#   build-bifrost.sh 1.2.0                   # build for an explicit version
#   build-bifrost.sh --no-txz                # skip .txz tarball
#   build-bifrost.sh --no-qcow2              # skip .qcow2 disk image
#   build-bifrost.sh --no-import             # skip OCI import (also skips -oci.tar)
#
# Produces (by default):
#   - Tarball     build/bifrost-<version>.txz
#   - Disk image  build/bifrost-<version>.qcow2
#   - OCI image   bifrost:<version> (in podman/docker)
#   - OCI archive build/bifrost-<version>-oci.tar
#
# Requires: tar, unshare.
# Optional: qemu-img, mkfs.ext4 (for --qcow2), podman or docker (for --import).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Defaults ────────────────────────────────────────────────────────
BUILD_DIR="$REPO_ROOT/build"
BIFROST_DIR="$REPO_ROOT/rootfs/bifrost"
VERSION_FILE="$REPO_ROOT/VERSION"
DO_IMPORT=true
DO_TXZ=true
DO_QCOW2=true
VERSION_ARG=""

HOSTKEYS_UNIT="$BIFROST_DIR/bifrost-hostkeys.service"
SYNC_UNIT="$BIFROST_DIR/bifrost-sshkey-sync.service"
SYNC_SCRIPT="$BIFROST_DIR/bifrost-sync-sshkeys.sh"

info()  { echo -e "\033[1;34m>>>\033[0m $*"; }
warn()  { echo -e "\033[1;33mWARN:\033[0m $*" >&2; }
error() { echo -e "\033[1;31mERROR:\033[0m $*" >&2; exit 1; }

# ── Usage ───────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] [VERSION]

Build the Bifrost derived image from an existing Yggdrasil .txz.

Bifrost = Yggdrasil + opinionated SSH layer (sshd enabled, host keys
generated at first boot, /etc/bifrost/authorized_keys sync).

Preconditions:
  build/yggdrasil-<VERSION>.txz must already exist. Run
  'bash rootfs/build-yggdrasil.sh' first if it does not.

Options:
      --no-import      Skip OCI import (also skips -oci.tar archive)
      --no-txz         Skip .txz tarball output
      --no-qcow2       Skip .qcow2 disk image output
  -h, --help           Show help

Arguments:
  VERSION              Version string (default: read from VERSION file)

Requires: tar, unshare.
Optional: qemu-img, mkfs.ext4 (for --qcow2), podman/docker (for --import).
EOF
}

# ── Parse arguments ─────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-import)     DO_IMPORT=false; shift ;;
        --no-txz)        DO_TXZ=false; shift ;;
        --no-qcow2)      DO_QCOW2=false; shift ;;
        -h|--help)       usage; exit 0 ;;
        -*)              echo "Error: unknown option: $1" >&2; usage >&2; exit 1 ;;
        *)
            if [[ -z "$VERSION_ARG" ]]; then
                VERSION_ARG="$1"; shift
            else
                echo "Error: unexpected argument: $1" >&2; usage >&2; exit 1
            fi
            ;;
    esac
done

# ── Version ─────────────────────────────────────────────────────────
if [[ -n "$VERSION_ARG" ]]; then
    VERSION="$VERSION_ARG"
else
    [[ -f "$VERSION_FILE" ]] || error "VERSION file not found: $VERSION_FILE"
    VERSION=$(tr -d '[:space:]' < "$VERSION_FILE")
fi
[[ -n "$VERSION" ]] || error "VERSION is empty"
IMAGE_TAG="bifrost:$VERSION"

YGG_TXZ="$BUILD_DIR/yggdrasil-${VERSION}.txz"
BIFROST_TXZ="$BUILD_DIR/bifrost-${VERSION}.txz"
BIFROST_QCOW2="$BUILD_DIR/bifrost-${VERSION}.qcow2"
BIFROST_OCI="$BUILD_DIR/bifrost-${VERSION}-oci.tar"

# ── Prerequisites ───────────────────────────────────────────────────
for tool in tar unshare; do
    command -v "$tool" >/dev/null 2>&1 || error "missing required tool: $tool"
done

if $DO_QCOW2; then
    command -v qemu-img  >/dev/null 2>&1 || error "missing qemu-img (needed for --qcow2)"
    command -v mkfs.ext4 >/dev/null 2>&1 || error "missing mkfs.ext4 (needed for --qcow2)"
fi

detect_container_cmd() {
    if command -v podman &>/dev/null; then
        echo podman
    elif command -v docker &>/dev/null; then
        echo docker
    else
        echo ""
    fi
}

CONTAINER_CMD=""
if $DO_IMPORT; then
    CONTAINER_CMD=$(detect_container_cmd)
    if [[ -z "$CONTAINER_CMD" ]]; then
        warn "neither podman nor docker found — skipping OCI import"
        DO_IMPORT=false
    fi
fi

[[ -f "$HOSTKEYS_UNIT" ]] || error "missing unit file: $HOSTKEYS_UNIT"
[[ -f "$SYNC_UNIT"     ]] || error "missing unit file: $SYNC_UNIT"
[[ -f "$SYNC_SCRIPT"   ]] || error "missing script:    $SYNC_SCRIPT"

# ── Precondition: yggdrasil .txz must exist ──────────────────────
if [[ ! -f "$YGG_TXZ" ]]; then
    error "$YGG_TXZ not found.
Bifrost is a derived image — it requires a post-Phase-1 Yggdrasil
tarball as its base. Run:

    bash rootfs/build-yggdrasil.sh

to produce build/yggdrasil-${VERSION}.txz first, then re-run this
script."
fi

# ── Cleanup ─────────────────────────────────────────────────────────
cleanup() {
    [[ -n "${WORK_DIR:-}" ]] && [[ -d "$WORK_DIR" ]] && rm -rf "$WORK_DIR" 2>/dev/null || true
    [[ -n "${SCRATCH:-}"  ]] && [[ -d "$SCRATCH"  ]] && rm -rf "$SCRATCH"  2>/dev/null || true
}
trap cleanup EXIT

# ── Stage overlay payload in scratch dir ───────────────────────────
SCRATCH=$(mktemp -d "/tmp/bifrost-scratch.XXXXXX")
WORK_DIR=$(mktemp -d "/tmp/bifrost-rootfs.XXXXXX")

cp "$HOSTKEYS_UNIT" "$SCRATCH/bifrost-hostkeys.service"
cp "$SYNC_UNIT"     "$SCRATCH/bifrost-sshkey-sync.service"
cp "$SYNC_SCRIPT"   "$SCRATCH/bifrost-sync-sshkeys.sh"

mkdir -p "$BUILD_DIR"

# ── Generate inner-phase.sh (runs inside unshare userns) ───────────
IMPORT_TAR="$SCRATCH/import.tar"

cat > "$SCRATCH/inner-phase.sh" <<INNER_EOF
#!/usr/bin/env bash
set -euo pipefail

WORK_DIR="$WORK_DIR"
SCRATCH="$SCRATCH"
VERSION="$VERSION"
BUILD_DIR="$BUILD_DIR"
YGG_TXZ="$YGG_TXZ"
BIFROST_TXZ="$BIFROST_TXZ"
BIFROST_QCOW2="$BIFROST_QCOW2"
IMPORT_TAR="$IMPORT_TAR"
DO_TXZ=$DO_TXZ
DO_QCOW2=$DO_QCOW2
DO_IMPORT=$DO_IMPORT

info()  { echo -e "\033[1;34m>>>\033[0m \$*"; }
warn()  { echo -e "\033[1;33mWARN:\033[0m \$*" >&2; }
error() { echo -e "\033[1;31mERROR:\033[0m \$*" >&2; exit 1; }

info "[userns] uid=\$(id -u) euid=\$EUID"

# ── Extract yggdrasil .txz ─────────────────────────────────────────
info "Extracting \$YGG_TXZ..."
tar -xJf "\$YGG_TXZ" -C "\$WORK_DIR"
[[ -d "\$WORK_DIR/etc" && -d "\$WORK_DIR/usr" ]] || error "extraction did not yield a rootfs"

# ── Install bifrost units + sync script ────────────────────────────
info "Installing bifrost systemd units..."
install -d -m 0755 "\$WORK_DIR/etc/systemd/system"
install -D -m 0644 "\$SCRATCH/bifrost-hostkeys.service" \
    "\$WORK_DIR/etc/systemd/system/bifrost-hostkeys.service"
install -D -m 0644 "\$SCRATCH/bifrost-sshkey-sync.service" \
    "\$WORK_DIR/etc/systemd/system/bifrost-sshkey-sync.service"

info "Installing bifrost-sync-sshkeys.sh..."
install -D -m 0755 "\$SCRATCH/bifrost-sync-sshkeys.sh" \
    "\$WORK_DIR/usr/local/sbin/bifrost-sync-sshkeys.sh"

info "Creating /etc/bifrost (staging dir)..."
install -d -m 0755 "\$WORK_DIR/etc/bifrost"

# ── Enable units via symlink creation (what systemctl enable does) ──
# ssh.service + ssh.socket live at /usr/lib/systemd/system/ in the
# Yggdrasil rootfs (canonical Debian path). Our own bifrost units live
# at /etc/systemd/system/ (just installed above). The .wants symlinks
# go under /etc/systemd/system/<target>.wants/ so we don't touch
# vendor-owned paths.
info "Enabling ssh.service, ssh.socket, bifrost-hostkeys, bifrost-sshkey-sync..."
install -d -m 0755 "\$WORK_DIR/etc/systemd/system/multi-user.target.wants"
install -d -m 0755 "\$WORK_DIR/etc/systemd/system/sockets.target.wants"

ln -sf /usr/lib/systemd/system/ssh.service \
    "\$WORK_DIR/etc/systemd/system/multi-user.target.wants/ssh.service"
ln -sf /usr/lib/systemd/system/ssh.socket \
    "\$WORK_DIR/etc/systemd/system/sockets.target.wants/ssh.socket"
ln -sf /etc/systemd/system/bifrost-hostkeys.service \
    "\$WORK_DIR/etc/systemd/system/multi-user.target.wants/bifrost-hostkeys.service"
ln -sf /etc/systemd/system/bifrost-sshkey-sync.service \
    "\$WORK_DIR/etc/systemd/system/multi-user.target.wants/bifrost-sshkey-sync.service"

FINAL_SIZE=\$(du -sh "\$WORK_DIR" 2>/dev/null | awk '{print \$1}')
info "Final rootfs size: \$FINAL_SIZE"

# ── Artifacts ──────────────────────────────────────────────────────
if \$DO_IMPORT; then
    info "Writing intermediate tarball for OCI import..."
    tar -cf "\$IMPORT_TAR" -C "\$WORK_DIR" .
fi

if \$DO_TXZ; then
    info "Writing .txz artifact \$BIFROST_TXZ..."
    tar -cJf "\$BIFROST_TXZ" -C "\$WORK_DIR" .
    info "Tarball size: \$(du -h "\$BIFROST_TXZ" | awk '{print \$1}')"
fi

if \$DO_QCOW2; then
    info "Building qcow2 disk image \$BIFROST_QCOW2..."
    RAW_IMG=\$(mktemp "/tmp/bifrost-raw.XXXXXX.raw")
    qemu-img create -f raw "\$RAW_IMG" 2G >/dev/null
    mkfs.ext4 -q -F -L bifrost -d "\$WORK_DIR" "\$RAW_IMG"
    qemu-img convert -c -f raw -O qcow2 "\$RAW_IMG" "\$BIFROST_QCOW2"
    rm -f "\$RAW_IMG"
    info "qcow2 size: \$(du -h "\$BIFROST_QCOW2" | awk '{print \$1}')"
fi

echo "\$FINAL_SIZE" > "\$SCRATCH/final-size"
INNER_EOF
chmod +x "$SCRATCH/inner-phase.sh"

# ── Run inner phase inside user+mount namespace ─────────────────────
info "Entering user+mount namespace for overlay phase..."
unshare --user --mount --map-root-user bash "$SCRATCH/inner-phase.sh"

FINAL_SIZE=$(cat "$SCRATCH/final-size" 2>/dev/null || echo "unknown")

# ── OCI import + save (outside userns) ─────────────────────────────
OCI_SAVED=false
if $DO_IMPORT; then
    info "Importing into $CONTAINER_CMD as $IMAGE_TAG..."
    # Expected failure path in kanibako (newuidmap limits on rootless
    # podman). Treat import as non-fatal so .txz + qcow2 remain the
    # usable primary artifacts in dev-container environments.
    if $CONTAINER_CMD import "$IMPORT_TAR" "$IMAGE_TAG"; then
        echo ""
        info "Image imported."
        $CONTAINER_CMD image inspect "$IMAGE_TAG" --format '{{.Size}}' 2>/dev/null | \
            awk '{printf "Image size: %.0f MB\n", $1/1024/1024}' || true

        info "Saving OCI archive to $BIFROST_OCI..."
        if $CONTAINER_CMD save --format=oci-archive -o "$BIFROST_OCI" "$IMAGE_TAG"; then
            OCI_SAVED=true
            info "OCI archive size: $(du -h "$BIFROST_OCI" | awk '{print $1}')"
        else
            warn "$CONTAINER_CMD save failed — skipping $BIFROST_OCI"
        fi
    else
        warn "$CONTAINER_CMD import failed (expected in kanibako due to"
        warn "newuidmap limits on rootless podman). .txz + qcow2 are"
        warn "still produced and are the primary artifacts."
    fi
fi

# ── Summary ─────────────────────────────────────────────────────────
echo ""
info "bifrost built successfully."
echo "  Source:   $YGG_TXZ"
echo "  Rootfs:   $FINAL_SIZE"
if $DO_TXZ;    then echo "  Tarball:  $BIFROST_TXZ"; fi
if $DO_QCOW2;  then echo "  qcow2:    $BIFROST_QCOW2"; fi
if $OCI_SAVED; then echo "  OCI:      $IMAGE_TAG ($CONTAINER_CMD)"; fi
if $OCI_SAVED; then echo "  Archive:  $BIFROST_OCI"; fi
