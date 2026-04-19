#!/usr/bin/env bash
#
# yggdrasil-unshim - Remove busybox shim symlinks for named packages
#
# Yggdrasil's rootfs shrink (rootfs/build-yggdrasil.sh, Phase 1) swaps ~18
# Debian packages for busybox symlinks: /usr/bin/ls, /usr/bin/gzip, etc. all
# point at /usr/bin/busybox instead of their real package binaries. This
# script is the inverse: it removes those symlinks so the real package can
# be reinstalled cleanly (`apt-get install <pkg>` would otherwise refuse to
# clobber a path owned by another package - or would silently overwrite the
# shim, leaving stale dangling entries in the manifest).
#
# Typical flow:
#   yggdrasil-unshim gzip sed
#   apt-get install gzip sed
#
# Manifests (written at build time by build-yggdrasil.sh):
#   /usr/share/yggdrasil/busybox-shim.manifest   pkg\tsymlink-path per line
#   /usr/share/yggdrasil/purged-packages.list    packages purged in Phase 2/4
#   /usr/share/yggdrasil/wiped-dirs.list         dirs fully wiped in Phase 3
#
# See yggdrasil-rehydrate(8) for a one-shot full restore.
#
# Usage:
#   yggdrasil-unshim <pkg> [pkg...]    Remove shims for the named packages
#   yggdrasil-unshim --all             Remove every shim in the manifest
#   yggdrasil-unshim --list            Print the shim manifest
#   yggdrasil-unshim -h | --help       Show help
#
set -euo pipefail

# --- Configuration -------------------------------------------------
MANIFEST="/usr/share/yggdrasil/busybox-shim.manifest"
BUSYBOX_PATH="/usr/bin/busybox"

# --- Helpers -------------------------------------------------------
info()  { echo -e "\033[1;34m>>>\033[0m $*"; }
warn()  { echo -e "\033[1;33mWARN:\033[0m $*" >&2; }
error() { echo -e "\033[1;31mERROR:\033[0m $*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
Usage: yggdrasil-unshim <pkg> [pkg...]
       yggdrasil-unshim --all
       yggdrasil-unshim --list
       yggdrasil-unshim -h | --help

Remove busybox shim symlinks installed by Yggdrasil's rootfs shrink so the
named packages can be reinstalled. Reads the manifest at:
  /usr/share/yggdrasil/busybox-shim.manifest

Options:
  <pkg> [pkg...]   Remove shims belonging to the listed packages
  --all            Remove every shim recorded in the manifest
  --list           Print the manifest (pkg <tab> path) and exit
  -h, --help       Show this help

After running, reinstall with `apt-get install <pkg>` to restore the real
binary. Exit codes: 0 success, 1 error, 2 invalid usage.
USAGE
}

# Read the manifest into two parallel arrays (pkgs, paths). Returns
# nonzero if the manifest is missing or empty, so the caller can warn
# and exit cleanly rather than treating it as a hard error.
load_manifest() {
    MANIFEST_PKGS=()
    MANIFEST_PATHS=()
    if [[ ! -f "$MANIFEST" ]]; then
        return 1
    fi
    if [[ ! -s "$MANIFEST" ]]; then
        return 1
    fi
    local pkg path
    while IFS=$'\t' read -r pkg path; do
        # Skip blank lines and comments
        [[ -z "${pkg:-}" ]] && continue
        [[ "$pkg" == \#* ]] && continue
        # Skip malformed lines (missing path column)
        if [[ -z "${path:-}" ]]; then
            warn "skipping malformed manifest line: $pkg"
            continue
        fi
        MANIFEST_PKGS+=("$pkg")
        MANIFEST_PATHS+=("$path")
    done < "$MANIFEST"
    return 0
}

# Remove a single shim path. Returns 0 if removed or already absent,
# 1 if we refused because the path is no longer a busybox symlink.
remove_shim() {
    local path="$1"

    if [[ ! -e "$path" && ! -L "$path" ]]; then
        # Already gone - nothing to do. Don't complain.
        return 0
    fi

    if [[ ! -L "$path" ]]; then
        warn "not a symlink, skipping: $path"
        return 1
    fi

    local target
    target=$(readlink "$path")
    if [[ "$target" != "$BUSYBOX_PATH" ]]; then
        warn "symlink target is not $BUSYBOX_PATH (got '$target'), skipping: $path"
        return 1
    fi

    rm -f "$path"
    info "removed shim: $path"
    return 0
}

# --- Commands ------------------------------------------------------

cmd_list() {
    if ! load_manifest; then
        warn "manifest missing or empty: $MANIFEST"
        return 0
    fi
    local i
    for i in "${!MANIFEST_PKGS[@]}"; do
        printf '%s\t%s\n' "${MANIFEST_PKGS[$i]}" "${MANIFEST_PATHS[$i]}"
    done
}

cmd_all() {
    if ! load_manifest; then
        warn "manifest missing or empty: $MANIFEST - nothing to unshim"
        return 0
    fi

    local rc=0
    local i
    local removed=0
    local skipped=0
    for i in "${!MANIFEST_PATHS[@]}"; do
        if remove_shim "${MANIFEST_PATHS[$i]}"; then
            removed=$((removed + 1))
        else
            skipped=$((skipped + 1))
            rc=1
        fi
    done
    info "removed $removed shim(s), skipped $skipped"
    return $rc
}

cmd_pkgs() {
    local requested=("$@")

    if ! load_manifest; then
        warn "manifest missing or empty: $MANIFEST - nothing to unshim"
        return 0
    fi

    local rc=0
    local pkg i
    local total_removed=0
    local total_skipped=0
    for pkg in "${requested[@]}"; do
        if [[ -z "$pkg" || "$pkg" == -* ]]; then
            error "invalid package name: '$pkg'"
        fi

        local matched=0
        local removed=0
        local skipped=0
        for i in "${!MANIFEST_PKGS[@]}"; do
            if [[ "${MANIFEST_PKGS[$i]}" == "$pkg" ]]; then
                matched=1
                if remove_shim "${MANIFEST_PATHS[$i]}"; then
                    removed=$((removed + 1))
                else
                    skipped=$((skipped + 1))
                    rc=1
                fi
            fi
        done

        if [[ $matched -eq 0 ]]; then
            warn "no shims in manifest for package: $pkg"
            rc=1
            continue
        fi
        info "$pkg: removed $removed, skipped $skipped"
        total_removed=$((total_removed + removed))
        total_skipped=$((total_skipped + skipped))
    done

    info "total: removed $total_removed shim(s), skipped $total_skipped"
    return $rc
}

# --- Main ----------------------------------------------------------

if [[ $# -eq 0 ]]; then
    usage >&2
    exit 2
fi

case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
    --list)
        if [[ $# -ne 1 ]]; then
            echo "Error: --list takes no arguments" >&2
            usage >&2
            exit 2
        fi
        cmd_list
        ;;
    --all)
        if [[ $# -ne 1 ]]; then
            echo "Error: --all takes no arguments" >&2
            usage >&2
            exit 2
        fi
        cmd_all
        ;;
    -*)
        echo "Error: unknown option: $1" >&2
        usage >&2
        exit 2
        ;;
    *)
        cmd_pkgs "$@"
        ;;
esac
