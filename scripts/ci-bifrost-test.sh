#!/usr/bin/env bash
#
# ci-bifrost-test — Tier 2 (systemd-in-OCI) check for bifrost
#
# Boots bifrost's systemd as PID 1 inside a rootless podman container
# and asserts:
#   - systemd reaches running / degraded within --timeout
#   - no unexpected failed units (allowlist inherited from yggdrasil + a
#     small bifrost-specific extension: first-boot units that have
#     successfully completed their oneshot pass)
#   - python3 and bash exec correctly
#   - systemd-analyze verify default.target succeeds
#   - ssh.service is ENABLED (bifrost contract: sshd enabled by default)
#   - SSH host keys are present in /etc/ssh/ (bifrost-hostkeys.service
#     fires at first boot and runs `ssh-keygen -A`)
#   - bifrost-sshkey-sync.service is ENABLED (but expected INACTIVE on
#     a vanilla image — no /etc/bifrost/authorized_keys to read from)
#
# Sibling to ci-systemd-test.sh (yggdrasil's Tier 2). Kept as a separate
# script rather than parameterizing the yggdrasil one because the two
# contracts differ meaningfully — bifrost wants ssh.service up, yggdrasil
# wants it *disabled*, and allowlists diverge.
#
# Shared podman-load / cleanup logic lives in lib/ci-podman-helpers.sh
# (Option A from the plan — extract is cleaner than two copies drifting).
#
# Designed for a vanilla ubuntu-24.04 GitHub runner with rootless podman.
# NOTE: cannot end-to-end-test this in the kanibako dev container —
# rootless podman is broken there (newuidmap permission issue; see
# ~/playbook/kanibako-limitations.md). Syntax-check only locally; real
# validation happens on the GH runner.
#
# Usage:
#   ci-bifrost-test.sh [--oci-archive PATH] [--version VER] [--timeout SEC] [-h|--help]
#
# Options:
#   --oci-archive PATH   Path to bifrost OCI archive
#                        (default: build/bifrost-<ver>-oci.tar)
#   --version VER        Version string (default: read from ./VERSION)
#   --timeout SEC        Seconds to wait for systemd to settle (default: 60)
#   -h, --help           Show this help
#
# Exit codes:
#   0   All checks passed
#   1   One or more checks failed
#   2   Usage error / missing prerequisite
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
Usage: ci-bifrost-test.sh [--oci-archive PATH] [--version VER] [--timeout SEC] [-h|--help]

Boot bifrost's systemd as PID 1 in rootless podman and assert health
plus bifrost's SSH-ready contract.

Options:
  --oci-archive PATH   Path to bifrost OCI archive
                       (default: build/bifrost-<ver>-oci.tar)
  --version VER        Version string (default: read from ./VERSION)
  --timeout SEC        Seconds to wait for systemd to settle (default: 60)
  -h, --help           Show this help

Exit codes:
  0  all checks passed
  1  one or more checks failed
  2  usage error / missing prerequisite
USAGE
}

# ─── Parse arguments ──────────────────────────────────────────────
OCI_ARCHIVE=""
VERSION=""
TIMEOUT=60

while [[ $# -gt 0 ]]; do
    case "$1" in
        --oci-archive)   OCI_ARCHIVE="$2";      shift 2 ;;
        --oci-archive=*) OCI_ARCHIVE="${1#*=}"; shift ;;
        --version)       VERSION="$2";          shift 2 ;;
        --version=*)     VERSION="${1#*=}";     shift ;;
        --timeout)       TIMEOUT="$2";          shift 2 ;;
        --timeout=*)     TIMEOUT="${1#*=}";     shift ;;
        -h|--help)       usage; exit 0 ;;
        *)               echo "Error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

# Resolve VERSION (needed for default archive path).
if [[ -z "$VERSION" ]]; then
    if [[ -f "./VERSION" ]]; then
        VERSION=$(tr -d '[:space:]' < ./VERSION)
    else
        error "no --version given and ./VERSION not found"
    fi
fi

[[ -n "$VERSION" ]] || error "--version must not be empty"

# Default archive path.
if [[ -z "$OCI_ARCHIVE" ]]; then
    OCI_ARCHIVE="build/bifrost-${VERSION}-oci.tar"
fi

# Validate timeout.
[[ "$TIMEOUT" =~ ^[0-9]+$ ]] || error "--timeout must be a positive integer (got: $TIMEOUT)"
[[ "$TIMEOUT" -ge 1 ]]       || error "--timeout must be >= 1"

# Validate archive exists.
[[ -f "$OCI_ARCHIVE" ]] || error "OCI archive not found: $OCI_ARCHIVE"

# ─── Prerequisites ────────────────────────────────────────────────
if ! command -v podman >/dev/null 2>&1; then
    error "podman not on PATH — install it (apt-get install -y podman) and retry"
fi

# ─── Source shared helpers ────────────────────────────────────────
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/ci-podman-helpers.sh
source "$SCRIPT_DIR/lib/ci-podman-helpers.sh"

# ─── State ────────────────────────────────────────────────────────
PASSED=0
FAILED=0

# Unique container name per run (parallel-CI safe).
RUN_TAG="$$-$(date +%s)"
CONTAINER_NAME="ci-bifrost-${RUN_TAG}"
CONTAINER_STARTED=0

# ─── Cleanup ──────────────────────────────────────────────────────
cleanup() {
    if (( CONTAINER_STARTED == 1 )); then
        podman stop --time 5 "$CONTAINER_NAME" >/dev/null 2>&1 || true
        podman rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    fi
    cih_cleanup_image
}
trap cleanup EXIT

# Dump recent container logs to stderr on failure for debugging.
dump_logs() {
    local why="$1"
    warn "dumping last 50 lines of container logs ($why):"
    podman logs --tail 50 "$CONTAINER_NAME" >&2 2>&1 || true
    echo "" >&2
}

info "OCI archive:  $OCI_ARCHIVE"
info "Version:      $VERSION"
info "Timeout:      ${TIMEOUT}s"
info "Container:    $CONTAINER_NAME"
echo ""

# ─── Check 1: Load OCI archive ────────────────────────────────────
info "Check 1: podman load -i $OCI_ARCHIVE"
cih_snapshot_images
if ! cih_load_image "$OCI_ARCHIVE"; then
    fail "podman load failed"
else
    if (( CIH_IMAGE_ADDED == 0 )); then
        info "image $CIH_IMAGE pre-existed in the store; cleanup will leave it intact"
    fi
    pass "loaded image: $CIH_IMAGE"
fi
echo ""

# If load failed outright, the remaining checks can't run.
if [[ -z "$CIH_IMAGE" ]]; then
    echo "─────────────────────────────────────────────"
    echo -e "\033[1;31m${PASSED} passed, ${FAILED} failed\033[0m (aborted after image load)"
    exit 1
fi

# ─── Check 2: Start container with systemd as PID 1 ───────────────
info "Check 2: start container with systemd (PID 1) via /sbin/init"
CID=""
if ! CID=$(podman run --rm --systemd=always -d \
        --name="$CONTAINER_NAME" \
        "$CIH_IMAGE" /sbin/init 2>&1); then
    echo "$CID" >&2
    CID=""
    fail "podman run failed"
else
    CONTAINER_STARTED=1
    pass "container started: ${CID:0:12}"
fi
echo ""

if (( CONTAINER_STARTED == 0 )); then
    echo "─────────────────────────────────────────────"
    echo -e "\033[1;31m${PASSED} passed, ${FAILED} failed\033[0m (aborted after container start)"
    exit 1
fi

# ─── Check 3: Wait for systemd to reach a stable state ────────────
info "Check 3: wait up to ${TIMEOUT}s for systemctl is-system-running"
STATE=""
ELAPSED=0
while (( ELAPSED < TIMEOUT )); do
    STATE=$(podman exec "$CONTAINER_NAME" systemctl is-system-running 2>&1 || true)
    STATE=$(echo "$STATE" | tail -1 | tr -d '[:space:]')
    case "$STATE" in
        running|degraded) break ;;
        offline|maintenance|stopping)
            fail "systemd entered fail-fast state: $STATE (after ${ELAPSED}s)"
            dump_logs "is-system-running=$STATE"
            STATE="__ABORT__"
            break
            ;;
        *) ;;
    esac
    sleep 1
    ELAPSED=$((ELAPSED + 1))
done

if [[ "$STATE" == "__ABORT__" ]]; then
    :
elif [[ "$STATE" == "running" || "$STATE" == "degraded" ]]; then
    pass "systemd reached '$STATE' after ${ELAPSED}s"
else
    fail "systemd did not settle within ${TIMEOUT}s (last state: '${STATE:-<empty>}')"
    dump_logs "is-system-running timeout (state=${STATE:-empty})"
fi
echo ""

if [[ "$STATE" == "__ABORT__" ]]; then
    echo "─────────────────────────────────────────────"
    echo -e "\033[1;31m${PASSED} passed, ${FAILED} failed\033[0m (aborted on systemd fail-fast)"
    exit 1
fi

# ─── Check 4: No unexpected failed units ──────────────────────────
info "Check 4: systemctl --failed (bifrost allowlist applied)"
# Inherited yggdrasil allowlist (container-irrelevant infrastructure)
# plus nothing new — bifrost's extra units (bifrost-hostkeys,
# bifrost-sshkey-sync, ssh) are all expected to succeed in a container.
# If any of them surface as failed in real CI, add here.
ALLOWLIST=(
    systemd-modules-load.service    # no access to host kernel modules
    systemd-udev-trigger.service    # no uevents in a container
    systemd-remount-fs.service      # container rootfs not mounted the expected way
    serial-getty@ttyS0.service      # no serial device
    getty@tty1.service              # no tty
)

FAILED_RAW=$(podman exec "$CONTAINER_NAME" \
    systemctl --failed --no-legend --plain 2>&1 || true)

UNEXPECTED=()
if [[ -n "$FAILED_RAW" ]]; then
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        unit=$(awk '{print $1}' <<<"$line")
        [[ -z "$unit" ]] && continue
        allowed=0
        for allow in "${ALLOWLIST[@]}"; do
            if [[ "$unit" == "$allow" ]]; then
                allowed=1
                break
            fi
        done
        if (( allowed == 0 )); then
            UNEXPECTED+=("$unit")
        fi
    done <<< "$FAILED_RAW"
fi

if (( ${#UNEXPECTED[@]} == 0 )); then
    pass "no unexpected failed units (allowlist: ${#ALLOWLIST[@]} units)"
else
    fail "${#UNEXPECTED[@]} unexpected failed unit(s): ${UNEXPECTED[*]}"
    warn "full --failed output:"
    echo "$FAILED_RAW" >&2
    for unit in "${UNEXPECTED[@]:0:3}"; do
        warn "status $unit:"
        podman exec "$CONTAINER_NAME" \
            systemctl status --no-pager --lines=10 "$unit" >&2 2>&1 || true
    done
fi
echo ""

# ─── Check 5: python3 works ───────────────────────────────────────
info "Check 5: /usr/bin/python3 --version"
PY_OUT=""
if ! PY_OUT=$(podman exec "$CONTAINER_NAME" /usr/bin/python3 --version 2>&1); then
    fail "python3 exec failed: $PY_OUT"
elif [[ "$PY_OUT" == Python\ 3.* ]]; then
    pass "python3 OK: $PY_OUT"
else
    fail "python3 output did not match 'Python 3.*': $PY_OUT"
fi
echo ""

# ─── Check 6: bash works ──────────────────────────────────────────
info "Check 6: /bin/bash -c 'echo hello_from_bifrost'"
BASH_OUT=""
if ! BASH_OUT=$(podman exec "$CONTAINER_NAME" /bin/bash -c 'echo hello_from_bifrost' 2>&1); then
    fail "bash exec failed: $BASH_OUT"
elif [[ "$BASH_OUT" == "hello_from_bifrost" ]]; then
    pass "bash OK"
else
    fail "bash output mismatch (got: '$BASH_OUT')"
fi
echo ""

# ─── Check 7: systemd-analyze verify default.target ───────────────
info "Check 7: systemd-analyze verify default.target"
VERIFY_OUT=""
if VERIFY_OUT=$(podman exec "$CONTAINER_NAME" \
        systemd-analyze verify default.target 2>&1); then
    pass "systemd-analyze verify default.target OK"
    if [[ -n "$VERIFY_OUT" ]]; then
        warn "verify emitted warnings (non-fatal):"
        echo "$VERIFY_OUT" >&2
    fi
else
    fail "systemd-analyze verify default.target reported errors"
    echo "$VERIFY_OUT" >&2
fi
echo ""

# ─── Check 8: ssh.service is enabled ──────────────────────────────
info "Check 8: ssh.service is enabled (bifrost SSH-ready contract)"
# `is-enabled` prints state on stdout; returns 0 for enabled/alias and
# non-zero for disabled/masked. Accept "enabled" (and "enabled-runtime"
# for completeness) — everything else is a contract violation.
SSH_STATE=$(podman exec "$CONTAINER_NAME" \
    systemctl is-enabled ssh.service 2>&1 || true)
SSH_STATE=$(echo "$SSH_STATE" | tail -1 | tr -d '[:space:]')
case "$SSH_STATE" in
    enabled|enabled-runtime|alias)
        pass "ssh.service is $SSH_STATE"
        ;;
    *)
        fail "ssh.service should be enabled, got: '$SSH_STATE'"
        ;;
esac
echo ""

# ─── Check 9: SSH host keys present ───────────────────────────────
info "Check 9: SSH host keys exist in /etc/ssh/ (bifrost-hostkeys.service contract)"
# bifrost-hostkeys.service runs `ssh-keygen -A` as an oneshot ordered
# Before=ssh.service, so by the time systemd reaches running/degraded
# the host keys must exist. ssh-keygen -A generates all key types the
# build has entropy for (rsa, ed25519 at minimum).
HOSTKEY_LIST=$(podman exec "$CONTAINER_NAME" \
    /bin/sh -c 'ls /etc/ssh/ssh_host_*_key 2>/dev/null | wc -l' 2>&1 \
    | tail -1 | tr -d '[:space:]')
if [[ "$HOSTKEY_LIST" =~ ^[0-9]+$ ]] && (( HOSTKEY_LIST >= 1 )); then
    pass "found $HOSTKEY_LIST SSH host key(s) in /etc/ssh/"
else
    fail "no SSH host keys present in /etc/ssh/ (bifrost-hostkeys.service did not fire?)"
    podman exec "$CONTAINER_NAME" \
        /bin/sh -c 'ls -la /etc/ssh/ 2>&1 || true' >&2 2>&1 || true
fi
echo ""

# ─── Check 10: bifrost-sshkey-sync.service is enabled ─────────────
info "Check 10: bifrost-sshkey-sync.service is enabled"
# The unit is enabled at build time. At runtime on a vanilla image the
# unit is expected to be INACTIVE (ConditionPathExists=/etc/bifrost/authorized_keys
# is false), but it must still be enabled — that's how a caller who
# stages the file gets the sync on the next boot.
SYNC_STATE=$(podman exec "$CONTAINER_NAME" \
    systemctl is-enabled bifrost-sshkey-sync.service 2>&1 || true)
SYNC_STATE=$(echo "$SYNC_STATE" | tail -1 | tr -d '[:space:]')
case "$SYNC_STATE" in
    enabled|enabled-runtime|alias)
        pass "bifrost-sshkey-sync.service is $SYNC_STATE"
        ;;
    *)
        fail "bifrost-sshkey-sync.service should be enabled, got: '$SYNC_STATE'"
        ;;
esac
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
