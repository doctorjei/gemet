#!/usr/bin/env bash
#
# test-yggdrasil-lxc — Minimum-viable LXC boot test for the Yggdrasil OCI image
#
# Exports the rootfs of a locally-available yggdrasil:<ver> OCI image into a
# temp directory, creates an LXC system container pointed at it, boots the
# container, and runs a handful of probes via lxc-attach to verify systemd
# came up and the expected Yggdrasil layout is present.
#
# Usage:
#   test-yggdrasil-lxc.sh [options]
#
# Options:
#   --image <tag>       OCI image tag to test (default: yggdrasil:<VERSION>)
#   --name <container>  LXC container name (default: yggdrasil-test-<pid>)
#   --keep              Don't destroy the container at the end (for debugging)
#   -h, --help          Show this help
#
# Requires: root (LXC system containers need it), lxc-* tools, podman or docker.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION_FILE="$REPO_ROOT/VERSION"

# ─── Helpers ───────────────────────────────────────────────────────

info()  { echo -e "\033[1;34m>>>\033[0m $*"; }
warn()  { echo -e "\033[1;33mWARN:\033[0m $*" >&2; }
error() { echo -e "\033[1;31mERROR:\033[0m $*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
Usage: test-yggdrasil-lxc.sh [options]

Boots a yggdrasil:<ver> OCI image as an LXC system container and runs a
short suite of probes (systemctl is-system-running, /etc/os-release,
/etc/yggdrasil existence, etc.) via lxc-attach.

Options:
  --image <tag>       OCI image tag to test (default: yggdrasil:<VERSION>)
  --name <container>  LXC container name (default: yggdrasil-test-<pid>)
  --keep              Don't destroy the container at the end (for debugging)
  -h, --help          Show this help

Must run as root. Requires lxc-create/lxc-start/lxc-attach/lxc-destroy and
either podman or docker for OCI rootfs extraction.
USAGE
    exit "${1:-0}"
}

# ─── Parse arguments ──────────────────────────────────────────────

default_version=""
[[ -f "$VERSION_FILE" ]] && default_version="$(tr -d '[:space:]' < "$VERSION_FILE")"
IMAGE="yggdrasil:${default_version:-latest}"
NAME="yggdrasil-test-$$"
KEEP=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --image) IMAGE="$2"; shift 2 ;;
        --name)  NAME="$2";  shift 2 ;;
        --keep)  KEEP=true;  shift ;;
        -h|--help) usage 0 ;;
        *) echo "Error: unknown option: $1" >&2; usage 1 ;;
    esac
done

# ─── Prerequisites ────────────────────────────────────────────────

if [[ $EUID -ne 0 ]]; then
    error "must run as root (LXC system containers require it)"
fi

for tool in lxc-create lxc-start lxc-attach lxc-destroy lxc-stop lxc-info; do
    command -v "$tool" &>/dev/null || \
        error "$tool not found. Install: apt install lxc podman"
done

if command -v podman &>/dev/null; then
    CONTAINER_CMD=podman
elif command -v docker &>/dev/null; then
    CONTAINER_CMD=docker
else
    error "neither podman nor docker found. Install: apt install lxc podman"
fi

$CONTAINER_CMD image inspect "$IMAGE" &>/dev/null || \
    error "OCI image '$IMAGE' not found locally. Build it first: sudo bash rootfs/build-yggdrasil.sh"

# ─── Cleanup ──────────────────────────────────────────────────────

ROOTFS_DIR=""
TEMP_CONTAINER=""
LXC_CREATED=false

cleanup() {
    if [[ "$LXC_CREATED" == "true" ]]; then
        if [[ "$KEEP" == "true" ]]; then
            info "Leaving container '$NAME' in place (--keep)."
            info "  Rootfs: $ROOTFS_DIR"
            info "  Config: /var/lib/lxc/$NAME/config"
            info "Clean up manually with: lxc-stop -n $NAME; lxc-destroy -n $NAME; rm -rf $ROOTFS_DIR"
        else
            lxc-info -n "$NAME" &>/dev/null && \
                lxc-stop -n "$NAME" --kill &>/dev/null || true
            lxc-destroy -n "$NAME" &>/dev/null || true
        fi
    fi
    if [[ -n "$TEMP_CONTAINER" ]]; then
        $CONTAINER_CMD rm "$TEMP_CONTAINER" &>/dev/null || true
    fi
    if [[ "$KEEP" != "true" && -n "$ROOTFS_DIR" && -d "$ROOTFS_DIR" ]]; then
        rm -rf "$ROOTFS_DIR"
    fi
}
trap cleanup EXIT

# ─── Extract OCI rootfs ───────────────────────────────────────────

ROOTFS_DIR=$(mktemp -d "/tmp/yggdrasil-lxc-rootfs.XXXXXX")
TEMP_CONTAINER="yggdrasil-export-$$"

info "Extracting '$IMAGE' rootfs to $ROOTFS_DIR..."
$CONTAINER_CMD create --name "$TEMP_CONTAINER" "$IMAGE" /bin/true >/dev/null
$CONTAINER_CMD export "$TEMP_CONTAINER" | tar -x -C "$ROOTFS_DIR"
$CONTAINER_CMD rm "$TEMP_CONTAINER" >/dev/null
TEMP_CONTAINER=""

# ─── Create LXC container ─────────────────────────────────────────

info "Creating LXC container '$NAME'..."
lxc-create -n "$NAME" -t none >/dev/null
LXC_CREATED=true

CONFIG_PATH="/var/lib/lxc/$NAME/config"
cat > "$CONFIG_PATH" <<EOF
# Minimum-viable Yggdrasil LXC boot test
lxc.rootfs.path = dir:$ROOTFS_DIR
lxc.uts.name = $NAME
lxc.arch = amd64
lxc.net.0.type = empty
EOF

# ─── Start container ──────────────────────────────────────────────

info "Starting container..."
lxc-start -n "$NAME" -d

info "Waiting for container to reach RUNNING state..."
for i in $(seq 1 30); do
    state=$(lxc-info -n "$NAME" -sH 2>/dev/null || echo "UNKNOWN")
    [[ "$state" == "RUNNING" ]] && break
    sleep 1
done
[[ "$state" == "RUNNING" ]] || error "container did not reach RUNNING (last state: $state)"

# Give systemd a few more seconds to settle
sleep 3

# ─── Probes ───────────────────────────────────────────────────────

info "Running probes..."
PASS=true

probe() {
    local label="$1"; shift
    if lxc-attach -n "$NAME" -- "$@"; then
        info "  PASS: $label"
    else
        warn "  FAIL: $label"
        PASS=false
    fi
}

info "--- systemctl is-system-running (running or degraded is acceptable) ---"
sys_state=$(lxc-attach -n "$NAME" -- systemctl is-system-running 2>&1 || true)
echo "  state: $sys_state"
case "$sys_state" in
    running|degraded|starting) info "  PASS: systemd is up ($sys_state)" ;;
    *) warn "  FAIL: unexpected systemd state: $sys_state"; PASS=false ;;
esac

info "--- /etc/os-release ---"
lxc-attach -n "$NAME" -- cat /etc/os-release || { PASS=false; warn "  FAIL: could not read /etc/os-release"; }

probe "id root"              id root
probe "ls /etc/yggdrasil"    ls -ld /etc/yggdrasil

info "--- systemctl status yggdrasil-sshkey-sync.service (informational) ---"
lxc-attach -n "$NAME" -- systemctl --no-pager status yggdrasil-sshkey-sync.service \
    || info "  (inactive/condition-failed is expected with no /etc/yggdrasil/authorized_keys)"

# ─── Summary ──────────────────────────────────────────────────────

echo ""
if [[ "$PASS" == "true" ]]; then
    info "RESULT: PASS — Yggdrasil booted as LXC container and probes succeeded."
    exit 0
else
    error "RESULT: FAIL — one or more probes failed. See output above."
fi
