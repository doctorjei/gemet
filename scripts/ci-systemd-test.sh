#!/usr/bin/env bash
#
# ci-systemd-test — Tier 2 (systemd-in-OCI) release-artifact check
#
# Boots the yggdrasil OCI image's systemd as PID 1 inside a rootless
# podman container and asserts it reaches a healthy state:
#   - is-system-running == running | degraded (within --timeout)
#   - no unexpected failed units (container-irrelevant units allowlisted)
#   - python3 and bash exec correctly
#   - systemd-analyze verify default.target succeeds
#
# Designed for a vanilla ubuntu-24.04 GitHub runner with rootless podman.
# NOTE: this script canNOT be tested in the kanibako dev container —
# rootless podman is broken there (newuidmap permission issue; see
# ~/playbook/kanibako-limitations.md). Syntax-check only locally; real
# validation happens on the GH runner.
#
# Usage:
#   ci-systemd-test.sh [--oci-archive PATH] [--version VER] [--timeout SEC] [-h|--help]
#
# Options:
#   --oci-archive PATH   Path to yggdrasil OCI archive
#                        (default: build/yggdrasil-<ver>-oci.tar)
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
Usage: ci-systemd-test.sh [--oci-archive PATH] [--version VER] [--timeout SEC] [-h|--help]

Boot yggdrasil's systemd as PID 1 in rootless podman and assert health.

Options:
  --oci-archive PATH   Path to yggdrasil OCI archive
                       (default: build/yggdrasil-<ver>-oci.tar)
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

# Default archive path.
if [[ -z "$OCI_ARCHIVE" ]]; then
    OCI_ARCHIVE="build/yggdrasil-${VERSION}-oci.tar"
fi

# Validate timeout.
[[ "$TIMEOUT" =~ ^[0-9]+$ ]] || error "--timeout must be a positive integer (got: $TIMEOUT)"
[[ "$TIMEOUT" -ge 1 ]]       || error "--timeout must be >= 1"

# Validate archive exists — do this before podman check so users with the
# default path who forgot to build get a clear filename-not-found message.
[[ -f "$OCI_ARCHIVE" ]] || error "OCI archive not found: $OCI_ARCHIVE"

# ─── Prerequisites ────────────────────────────────────────────────
if ! command -v podman >/dev/null 2>&1; then
    error "podman not on PATH — install it (apt-get install -y podman) and retry"
fi

# ─── State ────────────────────────────────────────────────────────
PASSED=0
FAILED=0

# Unique container + image marker per run (parallel-CI safe).
RUN_TAG="$$-$(date +%s)"
CONTAINER_NAME="ci-yggdrasil-${RUN_TAG}"
IMAGE=""
IMAGE_ADDED=0      # 1 if podman load added a new image — gates cleanup rmi
CID=""             # container ID once started
CONTAINER_STARTED=0

# ─── Cleanup ──────────────────────────────────────────────────────
cleanup() {
    if (( CONTAINER_STARTED == 1 )); then
        podman stop --time 5 "$CONTAINER_NAME" >/dev/null 2>&1 || true
        # --rm on the original run should auto-remove, but be defensive.
        podman rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    fi
    if (( IMAGE_ADDED == 1 )) && [[ -n "$IMAGE" ]]; then
        podman rmi -f "$IMAGE" >/dev/null 2>&1 || true
    fi
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

# Snapshot the image list before load so cleanup can distinguish
# "we added this image" from "image was already in the store, our load
# was a no-op." Without this check, an unconditional rmi on exit would
# wipe an image a caller (e.g., the release workflow's build step) had
# staged before invoking us, breaking downstream steps.
PRE_LOAD_IMAGES=$(podman images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null || true)

LOAD_OUT=""
if ! LOAD_OUT=$(podman load -i "$OCI_ARCHIVE" 2>&1); then
    echo "$LOAD_OUT" >&2
    fail "podman load failed"
else
    # `podman load` prints one or more lines like:
    #   Loaded image: localhost/yggdrasil:1.2.0
    #   Loaded image(s): localhost/yggdrasil:1.2.0
    # Parse the last "Loaded image" line's final field.
    IMAGE=$(echo "$LOAD_OUT" | awk '/Loaded image/ {img=$NF} END{print img}')
    if [[ -z "$IMAGE" ]]; then
        # Fallback: grab any token that looks like a tagged image ref.
        IMAGE=$(echo "$LOAD_OUT" | grep -oE '[a-zA-Z0-9._/-]+:[a-zA-Z0-9._-]+' | tail -1)
    fi
    if [[ -z "$IMAGE" ]]; then
        echo "$LOAD_OUT" >&2
        fail "could not parse loaded image name from podman load output"
    else
        if echo "$PRE_LOAD_IMAGES" | grep -Fxq "$IMAGE"; then
            info "image $IMAGE pre-existed in the store; cleanup will leave it intact"
            IMAGE_ADDED=0
        else
            IMAGE_ADDED=1
        fi
        pass "loaded image: $IMAGE"
    fi
fi
echo ""

# If load failed outright, the remaining checks can't run. Report and exit.
# $IMAGE is the load-succeeded signal (set only when parse succeeded);
# $IMAGE_ADDED is purely about cleanup ownership and is unrelated here.
if [[ -z "$IMAGE" ]]; then
    echo "─────────────────────────────────────────────"
    echo -e "\033[1;31m${PASSED} passed, ${FAILED} failed\033[0m (aborted after image load)"
    exit 1
fi

# ─── Check 2: Start container with systemd as PID 1 ───────────────
info "Check 2: start container with systemd (PID 1) via /sbin/init"
# --systemd=always enables cgroup delegation and the tmpfs mounts systemd
# expects. The yggdrasil image has no CMD, so we explicitly invoke
# /sbin/init (which is systemd).
if ! CID=$(podman run --rm --systemd=always -d \
        --name="$CONTAINER_NAME" \
        "$IMAGE" /sbin/init 2>&1); then
    echo "$CID" >&2
    CID=""
    fail "podman run failed"
else
    CONTAINER_STARTED=1
    pass "container started: ${CID:0:12}"
fi
echo ""

# If the container didn't start, no further exec-based checks can run.
if (( CONTAINER_STARTED == 0 )); then
    echo "─────────────────────────────────────────────"
    echo -e "\033[1;31m${PASSED} passed, ${FAILED} failed\033[0m (aborted after container start)"
    exit 1
fi

# ─── Check 3: Wait for systemd to reach a stable state ────────────
info "Check 3: wait up to ${TIMEOUT}s for systemctl is-system-running"
STATE=""
ELAPSED=0
# Accept: running, degraded. Fail-fast: offline, maintenance, stopping.
# Keep polling while: starting, initializing, (empty / error on early poll).
while (( ELAPSED < TIMEOUT )); do
    # is-system-running prints state on stdout; exit code is 0 for running,
    # nonzero for anything else (including degraded/starting). We only care
    # about the string.
    STATE=$(podman exec "$CONTAINER_NAME" systemctl is-system-running 2>&1 || true)
    # Normalize: take the last line (systemctl may print 'initializing' +
    # a warning on early polls) and trim whitespace.
    STATE=$(echo "$STATE" | tail -1 | tr -d '[:space:]')

    case "$STATE" in
        running|degraded)
            break
            ;;
        offline|maintenance|stopping)
            fail "systemd entered fail-fast state: $STATE (after ${ELAPSED}s)"
            dump_logs "is-system-running=$STATE"
            STATE="__ABORT__"
            break
            ;;
        *)
            # starting, initializing, empty, or error — keep polling.
            ;;
    esac

    sleep 1
    ELAPSED=$((ELAPSED + 1))
done

if [[ "$STATE" == "__ABORT__" ]]; then
    :  # already failed above
elif [[ "$STATE" == "running" || "$STATE" == "degraded" ]]; then
    pass "systemd reached '$STATE' after ${ELAPSED}s"
else
    fail "systemd did not settle within ${TIMEOUT}s (last state: '${STATE:-<empty>}')"
    dump_logs "is-system-running timeout (state=${STATE:-empty})"
fi
echo ""

# Remaining checks require a usable container; skip if we aborted at
# fail-fast. A timeout still lets us try the rest — systemd may be degraded
# but units can still be introspected.
if [[ "$STATE" == "__ABORT__" ]]; then
    echo "─────────────────────────────────────────────"
    echo -e "\033[1;31m${PASSED} passed, ${FAILED} failed\033[0m (aborted on systemd fail-fast)"
    exit 1
fi

# ─── Check 4: No unexpected failed units ──────────────────────────
info "Check 4: systemctl --failed (allowlist applied)"
# Allowlist: units that are expected to fail inside a container because the
# required hardware/subsystem isn't present. Grow this as real CI runs
# surface additional unavoidable failures.
ALLOWLIST=(
    systemd-modules-load.service    # no access to host kernel modules
    systemd-udev-trigger.service    # no uevents in a container
    systemd-remount-fs.service      # container rootfs not mounted the expected way
    serial-getty@ttyS0.service      # no serial device
    getty@tty1.service              # no tty
    systemd-resolved.service        # User=systemd-resolve setuid fails in rootless-podman userns (217/USER); runs fine in a real VM
)

# Output format: "UNIT LOAD ACTIVE SUB DESCRIPTION" (one per line, plain).
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
    # Show status for the first few unexpected units to aid debugging.
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
info "Check 6: /bin/bash -c 'echo hello_from_yggdrasil'"
BASH_OUT=""
if ! BASH_OUT=$(podman exec "$CONTAINER_NAME" /bin/bash -c 'echo hello_from_yggdrasil' 2>&1); then
    fail "bash exec failed: $BASH_OUT"
elif [[ "$BASH_OUT" == "hello_from_yggdrasil" ]]; then
    pass "bash OK"
else
    fail "bash output mismatch (got: '$BASH_OUT')"
fi
echo ""

# ─── Check 7: systemd-analyze verify default.target ───────────────
info "Check 7: systemd-analyze verify default.target"
# verify's exit code reflects *errors* only; warnings go to stderr but
# exit 0. Capture both streams but judge on exit code.
VERIFY_OUT=""
if VERIFY_OUT=$(podman exec "$CONTAINER_NAME" \
        systemd-analyze verify default.target 2>&1); then
    pass "systemd-analyze verify default.target OK"
    if [[ -n "$VERIFY_OUT" ]]; then
        # Warnings are informational — surface them but don't fail.
        warn "verify emitted warnings (non-fatal):"
        echo "$VERIFY_OUT" >&2
    fi
else
    fail "systemd-analyze verify default.target reported errors"
    echo "$VERIFY_OUT" >&2
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
