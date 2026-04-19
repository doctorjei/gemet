#!/usr/bin/env bash
#
# yggdrasil-rehydrate - Restore full-Debian behavior on a shrunk Yggdrasil VM
#
# Yggdrasil ships an aggressively shrunk Debian 13 rootfs: busybox shims
# replace ~18 utility packages (Phase 1), ~36 packages are purged outright
# (Phases 2/4 - locales, libmagic, python3-* libs, ...), and /usr/share/doc,
# /usr/share/info, most of /usr/share/man and /usr/share/locale are wiped
# (Phase 3). This script reverses all of that in one shot - useful for
# downstream users who want the full Debian experience or need to debug
# something that assumes standard tooling/docs.
#
# It is the bigger hammer next to yggdrasil-unshim(8), which surgically
# removes individual shims so specific packages can be reinstalled.
#
# Steps:
#   1. Remove every busybox shim (yggdrasil-unshim --all)
#   2. apt-get update
#   3. apt-get install every package in purged-packages.list
#   4. apt-get install --reinstall every currently-installed package,
#      which restores wiped /usr/share/{doc,info,man,locale} contents
#   5. Print a summary
#
# Manifests (written at build time by build-yggdrasil.sh):
#   /usr/share/yggdrasil/purged-packages.list    packages purged, one per line
#   /usr/share/yggdrasil/busybox-shim.manifest   pkg\tsymlink-path per line
#   /usr/share/yggdrasil/wiped-dirs.list         dirs fully wiped, one per line
#
# Usage:
#   yggdrasil-rehydrate             Run the full restore (requires root)
#   yggdrasil-rehydrate --dry-run   Print what would happen; change nothing
#   yggdrasil-rehydrate -h | --help Show help
#
set -euo pipefail

# --- Configuration -------------------------------------------------
MANIFEST_DIR="/usr/share/yggdrasil"
PURGED_LIST="$MANIFEST_DIR/purged-packages.list"
SHIM_MANIFEST="$MANIFEST_DIR/busybox-shim.manifest"
WIPED_DIRS="$MANIFEST_DIR/wiped-dirs.list"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNSHIM="$SCRIPT_DIR/yggdrasil-unshim.sh"
# Fall back to PATH if the sibling script isn't alongside us (e.g. packaged
# into /usr/local/sbin/yggdrasil-unshim).
if [[ ! -x "$UNSHIM" ]]; then
    if command -v yggdrasil-unshim &>/dev/null; then
        UNSHIM="$(command -v yggdrasil-unshim)"
    fi
fi

DRY_RUN=false

# --- Helpers -------------------------------------------------------
info()  { echo -e "\033[1;34m>>>\033[0m $*"; }
warn()  { echo -e "\033[1;33mWARN:\033[0m $*" >&2; }
error() { echo -e "\033[1;31mERROR:\033[0m $*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
Usage: yggdrasil-rehydrate [--dry-run]
       yggdrasil-rehydrate -h | --help

Restore the full-Debian experience on a shrunk Yggdrasil rootfs. Removes
every busybox shim, reinstalls every package purged by the Yggdrasil build,
and reinstalls every currently-installed package to bring back wiped
/usr/share/{doc,info,man,locale} content.

Reads build-time manifests from /usr/share/yggdrasil/.

Options:
  --dry-run     Print what would happen but make no changes
  -h, --help    Show this help

Requires root. The reinstall pass is slow (2-5 min on a fresh Yggdrasil).
USAGE
}

# Run a command, or just echo it under --dry-run.
run() {
    if $DRY_RUN; then
        echo "  [dry-run] $*"
    else
        "$@"
    fi
}

# Count lines in a file, ignoring blanks and comments. Prints 0 if the
# file is missing.
count_entries() {
    local f="$1"
    if [[ ! -f "$f" ]]; then
        echo 0
        return
    fi
    grep -cvE '^(#|$)' "$f" 2>/dev/null || echo 0
}

# --- Parse arguments -----------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)   DRY_RUN=true; shift ;;
        -h|--help)   usage; exit 0 ;;
        -*)          echo "Error: unknown option: $1" >&2; usage >&2; exit 2 ;;
        *)           echo "Error: unexpected argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

# --- Prerequisites -------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    error "must run as root (apt-get, symlink removal)"
fi

if [[ ! -x "$UNSHIM" ]]; then
    error "yggdrasil-unshim not found (looked next to this script and in PATH)"
fi

if ! command -v apt-get &>/dev/null; then
    error "apt-get not found - this script only runs on Debian/Ubuntu"
fi

# --- Banner --------------------------------------------------------
PURGED_COUNT=$(count_entries "$PURGED_LIST")
SHIM_COUNT=$(count_entries "$SHIM_MANIFEST")
WIPED_COUNT=$(count_entries "$WIPED_DIRS")
INSTALLED_COUNT=$(dpkg -l 2>/dev/null | awk '/^ii/{c++} END{print c+0}')

echo ""
info "Yggdrasil rehydrate"
echo "  purged packages to reinstall : $PURGED_COUNT"
echo "  busybox shims to remove      : $SHIM_COUNT"
echo "  wiped dirs to refill         : $WIPED_COUNT"
echo "  existing packages to refresh : $INSTALLED_COUNT"
echo ""
echo "This will reinstall ~$((PURGED_COUNT + INSTALLED_COUNT)) packages and take ~2-5 min."
if $DRY_RUN; then
    echo "  (dry-run: no changes will be made)"
fi
echo ""

# --- Step 1: Remove busybox shims ----------------------------------
info "Step 1/5: Removing busybox shims..."
if [[ -f "$SHIM_MANIFEST" && -s "$SHIM_MANIFEST" ]]; then
    if $DRY_RUN; then
        echo "  [dry-run] $UNSHIM --all"
    else
        # --all returns nonzero if any individual shim was skipped (e.g.
        # the path is no longer a busybox symlink because the user already
        # reinstalled the package). That's fine for rehydrate - keep going.
        "$UNSHIM" --all || warn "some shims could not be removed (see warnings above)"
    fi
else
    warn "shim manifest missing or empty: $SHIM_MANIFEST - skipping"
fi

# --- Step 2: apt-get update ----------------------------------------
info "Step 2/5: Refreshing apt indexes..."
run apt-get update

# --- Step 3: Reinstall purged packages -----------------------------
info "Step 3/5: Reinstalling purged packages..."
if [[ ! -f "$PURGED_LIST" ]]; then
    warn "purged-packages list missing: $PURGED_LIST - skipping"
    RESTORED_PURGED=0
elif [[ ! -s "$PURGED_LIST" ]]; then
    warn "purged-packages list empty: $PURGED_LIST - skipping"
    RESTORED_PURGED=0
else
    # Filter blanks and comments
    PKGS=()
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        [[ "$line" == \#* ]] && continue
        PKGS+=("$line")
    done < "$PURGED_LIST"

    if [[ ${#PKGS[@]} -eq 0 ]]; then
        warn "purged-packages list contains no installable entries - skipping"
        RESTORED_PURGED=0
    else
        export DEBIAN_FRONTEND=noninteractive
        run apt-get install -y "${PKGS[@]}"
        RESTORED_PURGED=${#PKGS[@]}
    fi
fi

# --- Step 4: Reinstall existing packages to refill wiped dirs ------
info "Step 4/5: Reinstalling existing packages to restore docs/man/locale..."
info "  (this is the slow step - 2-5 min)"

INSTALLED_PKGS=$(dpkg -l 2>/dev/null | awk '/^ii/{print $2}')
REINSTALLED_COUNT=0
if [[ -z "$INSTALLED_PKGS" ]]; then
    warn "no installed packages found - skipping reinstall pass"
else
    export DEBIAN_FRONTEND=noninteractive
    # xargs handles the long argument list; -r keeps it a no-op on empty input.
    if $DRY_RUN; then
        REINSTALLED_COUNT=$(echo "$INSTALLED_PKGS" | wc -l)
        echo "  [dry-run] apt-get install --reinstall -y <$REINSTALLED_COUNT packages>"
    else
        echo "$INSTALLED_PKGS" \
            | xargs -r apt-get install --reinstall -y --no-install-recommends
        REINSTALLED_COUNT=$(echo "$INSTALLED_PKGS" | wc -l)
    fi
fi

# --- Step 5: Summary -----------------------------------------------
info "Step 5/5: Done."
echo ""
if $DRY_RUN; then
    echo "Dry-run complete. Would have:"
    echo "  - removed up to $SHIM_COUNT busybox shims"
    echo "  - restored $RESTORED_PURGED purged package(s)"
    echo "  - reinstalled $REINSTALLED_COUNT existing package(s)"
else
    echo "Rehydrate complete:"
    echo "  - removed up to $SHIM_COUNT busybox shim(s)"
    echo "  - restored $RESTORED_PURGED purged package(s)"
    echo "  - reinstalled $REINSTALLED_COUNT existing package(s)"
    echo ""
    echo "You may want to log out and back in so new man/info paths are picked up."
fi
