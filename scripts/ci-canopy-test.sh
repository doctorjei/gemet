#!/usr/bin/env bash
#
# ci-canopy-test — Tier 2 (structural-runtime) check for canopy
#
# Canopy has no pid1 — systemd, udev, dbus, and the init-family are all
# purged. `podman run --systemd=always` is meaningless here (there's
# nothing to run as PID 1, and the OCI image has no CMD). So instead
# of the systemd-in-OCI pattern used by ci-systemd-test.sh (yggdrasil)
# and ci-bifrost-test.sh (bifrost), this script runs a one-shot
# process-container check:
#
#   podman run --rm canopy:<ver> /bin/sh -c '<checks>'
#
# And asserts:
#   - exit 0
#   - apt-get --version parses
#   - bash --version parses
#   - dpkg -l package count is in the expected canopy range
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
#   ci-canopy-test.sh [--oci-archive PATH] [--version VER] [-h|--help]
#
# Options:
#   --oci-archive PATH   Path to canopy OCI archive
#                        (default: build/canopy-<ver>-oci.tar)
#   --version VER        Version string (default: read from ./VERSION)
#   -h, --help           Show this help
#
# Exit codes:
#   0   All checks passed
#   1   One or more checks failed
#   2   Usage error / missing prerequisite
#
set -euo pipefail

# Expected canopy package count band. Spike produced 187 packages;
# leave a small margin for upstream Debian drift in the yggdrasil base.
CANOPY_PKG_MIN=180
CANOPY_PKG_MAX=195

# ─── Helpers ──────────────────────────────────────────────────────
info()  { echo -e "\033[1;34m>>>\033[0m $*"; }
warn()  { echo -e "\033[1;33mWARN:\033[0m $*" >&2; }
error() { echo -e "\033[1;31mERROR:\033[0m $*" >&2; exit 2; }

pass()  { echo -e "\033[1;32m[PASS]\033[0m $*"; PASSED=$((PASSED + 1)); }
fail()  { echo -e "\033[1;31m[FAIL]\033[0m $*" >&2; FAILED=$((FAILED + 1)); }

usage() {
    cat <<'USAGE'
Usage: ci-canopy-test.sh [--oci-archive PATH] [--version VER] [-h|--help]

Run canopy's no-pid1 structural-runtime check in rootless podman.
Asserts the image is a usable process-container base (apt + bash work).

Options:
  --oci-archive PATH   Path to canopy OCI archive
                       (default: build/canopy-<ver>-oci.tar)
  --version VER        Version string (default: read from ./VERSION)
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

while [[ $# -gt 0 ]]; do
    case "$1" in
        --oci-archive)   OCI_ARCHIVE="$2";      shift 2 ;;
        --oci-archive=*) OCI_ARCHIVE="${1#*=}"; shift ;;
        --version)       VERSION="$2";          shift 2 ;;
        --version=*)     VERSION="${1#*=}";     shift ;;
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
    OCI_ARCHIVE="build/canopy-${VERSION}-oci.tar"
fi

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

# ─── Cleanup ──────────────────────────────────────────────────────
cleanup() {
    cih_cleanup_image
}
trap cleanup EXIT

info "OCI archive:  $OCI_ARCHIVE"
info "Version:      $VERSION"
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

if [[ -z "$CIH_IMAGE" ]]; then
    echo "─────────────────────────────────────────────"
    echo -e "\033[1;31m${PASSED} passed, ${FAILED} failed\033[0m (aborted after image load)"
    exit 1
fi

# ─── Check 2: Container runs + exits 0 ────────────────────────────
info "Check 2: podman run --rm canopy:<ver> /bin/sh -c '<probes>'"
# Single multi-command sh -c so we pay one container-startup cost, not
# three. Prints sentinel tokens for each probe so we can parse them out
# of the combined stdout.
#
# Probes (all inside the running container):
#   ALIVE          — container started, /bin/sh runs
#   APT=<line>     — first line of `apt-get --version`
#   BASH=<line>    — first line of `bash --version`
#   DPKG=<count>   — count of installed packages per `dpkg -l`
#
# `dpkg -l` output has 5-line header and one line per package. Filter
# to lines whose first column is `ii` (installed). That's the canonical
# way to count installed packages.
PROBE_CMD='\
set -e; \
echo "ALIVE"; \
echo "APT=$(apt-get --version 2>&1 | head -1)"; \
echo "BASH=$(bash --version 2>&1 | head -1)"; \
echo "DPKG=$(dpkg -l 2>/dev/null | awk "\$1==\"ii\"{c++} END{print c+0}")"'

RUN_OUT=""
if ! RUN_OUT=$(podman run --rm "$CIH_IMAGE" /bin/sh -c "$PROBE_CMD" 2>&1); then
    fail "podman run exited non-zero"
    warn "output:"
    echo "$RUN_OUT" >&2
    echo "─────────────────────────────────────────────"
    echo -e "\033[1;31m${PASSED} passed, ${FAILED} failed\033[0m (aborted after container run)"
    exit 1
else
    pass "container ran /bin/sh probes and exited 0"
fi
echo ""

# ─── Check 3: ALIVE sentinel present ──────────────────────────────
info "Check 3: ALIVE sentinel present"
if echo "$RUN_OUT" | grep -Fxq "ALIVE"; then
    pass "ALIVE sentinel found"
else
    fail "no ALIVE sentinel in container output"
    warn "full output:"
    echo "$RUN_OUT" >&2
fi
echo ""

# ─── Check 4: apt-get --version parses ────────────────────────────
info "Check 4: apt-get --version parses"
APT_LINE=$(echo "$RUN_OUT" | awk -F= '/^APT=/{sub(/^APT=/,""); print; exit}')
# Canonical: "apt 2.x.y (architecture)" — just check the prefix.
if [[ "$APT_LINE" == apt\ * ]]; then
    pass "apt-get OK: $APT_LINE"
else
    fail "apt-get --version output unexpected: '$APT_LINE'"
fi
echo ""

# ─── Check 5: bash --version parses ───────────────────────────────
info "Check 5: bash --version parses"
BASH_LINE=$(echo "$RUN_OUT" | awk -F= '/^BASH=/{sub(/^BASH=/,""); print; exit}')
# Canonical: "GNU bash, version 5.x.y(1)-release (x86_64-pc-linux-gnu)"
if [[ "$BASH_LINE" == *bash* && "$BASH_LINE" == *version* ]]; then
    pass "bash OK: $BASH_LINE"
else
    fail "bash --version output unexpected: '$BASH_LINE'"
fi
echo ""

# ─── Check 6: dpkg package count in expected range ────────────────
info "Check 6: dpkg installed-package count in ${CANOPY_PKG_MIN}-${CANOPY_PKG_MAX}"
DPKG_COUNT=$(echo "$RUN_OUT" | awk -F= '/^DPKG=/{sub(/^DPKG=/,""); print; exit}')
if [[ "$DPKG_COUNT" =~ ^[0-9]+$ ]] \
   && (( DPKG_COUNT >= CANOPY_PKG_MIN )) \
   && (( DPKG_COUNT <= CANOPY_PKG_MAX )); then
    pass "dpkg reports $DPKG_COUNT installed packages (in range)"
else
    fail "dpkg count '$DPKG_COUNT' outside ${CANOPY_PKG_MIN}-${CANOPY_PKG_MAX}"
    warn "full container output:"
    echo "$RUN_OUT" >&2
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
