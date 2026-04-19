#!/usr/bin/env bash
#
# build-kernel-oci — Package tenkei's kernel + initramfs as an OCI image
#
# Wraps `podman build` to produce a single-layer image containing
# /boot/vmlinuz and /boot/initramfs.img, tagged tenkei-kernel:<version>
# (and tenkei-kernel:latest for convenience).
#
# Usage:
#   build-kernel-oci [version]
#
# If version is omitted, the contents of ./VERSION are used.
#
# Prerequisite: run scripts/build-kernel.sh first so that
# build/vmlinuz and build/tenkei-initramfs.img exist.
#
# Run from the root of your tenkei repository.
#
set -euo pipefail

# ─── Configuration ─────────────────────────────────────────────────

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="${REPO_ROOT}/VERSION"
CONTAINERFILE="${REPO_ROOT}/kernel/Containerfile"
BUILD_DIR="${REPO_ROOT}/build"
KERNEL_SRC="${BUILD_DIR}/vmlinuz"
INITRAMFS_SRC="${BUILD_DIR}/tenkei-initramfs.img"
IMAGE_NAME="tenkei-kernel"

# ─── Helpers ───────────────────────────────────────────────────────

info()  { echo -e "\033[1;34m>>>\033[0m $*"; }
warn()  { echo -e "\033[1;33mWARN:\033[0m $*" >&2; }
error() { echo -e "\033[1;31mERROR:\033[0m $*" >&2; exit 1; }

# ─── Main ──────────────────────────────────────────────────────────

usage() {
    cat <<'USAGE'
Usage: build-kernel-oci [version]

Builds an OCI image tagged tenkei-kernel:<version> (and :latest)
containing /boot/vmlinuz and /boot/initramfs.img, sourced from
build/vmlinuz and build/tenkei-initramfs.img.

If version is omitted, the contents of ./VERSION are used.
USAGE
    exit "${1:-1}"
}

case "${1:-}" in
    -h|--help) usage 0 ;;
esac

resolve_version() {
    local ver="${1:-}"
    if [[ -z "$ver" ]]; then
        [[ -f "$VERSION_FILE" ]] || \
            error "VERSION file not found at ${VERSION_FILE}"
        ver="$(tr -d '[:space:]' < "$VERSION_FILE")"
    else
        ver="$(echo -n "$ver" | tr -d '[:space:]')"
    fi
    [[ -n "$ver" ]] || error "Version string is empty"
    echo "$ver"
}

check_inputs() {
    [[ -f "$CONTAINERFILE" ]] || \
        error "Containerfile not found at ${CONTAINERFILE}"

    local missing=()
    [[ -f "$KERNEL_SRC" ]]    || missing+=("$KERNEL_SRC")
    [[ -f "$INITRAMFS_SRC" ]] || missing+=("$INITRAMFS_SRC")

    if (( ${#missing[@]} > 0 )); then
        warn "Missing build artifacts:"
        for f in "${missing[@]}"; do
            warn "  $f"
        done
        error "Run 'bash scripts/build-kernel.sh <version>' first to produce them."
    fi

    command -v podman &>/dev/null || \
        error "podman not found in PATH"
}

stage_context() {
    local staging="$1"

    info "Staging build context at ${staging}..."
    # Hardlink when possible to avoid copying large files; fall back to cp.
    cp -l "$KERNEL_SRC"    "${staging}/vmlinuz"       2>/dev/null \
        || cp "$KERNEL_SRC"    "${staging}/vmlinuz"
    cp -l "$INITRAMFS_SRC" "${staging}/initramfs.img" 2>/dev/null \
        || cp "$INITRAMFS_SRC" "${staging}/initramfs.img"
}

build_image() {
    local version="$1"
    local staging="$2"
    local versioned_tag="${IMAGE_NAME}:${version}"
    local latest_tag="${IMAGE_NAME}:latest"

    info "Building ${versioned_tag}..."
    podman build \
        -t "$versioned_tag" \
        -t "$latest_tag" \
        -f "$CONTAINERFILE" \
        "$staging"

    local image_id
    image_id=$(podman image inspect --format '{{.Id}}' "$versioned_tag")

    echo ""
    info "Built image:"
    echo "  Tag:      ${versioned_tag}"
    echo "  Also:     ${latest_tag}"
    echo "  ID:       ${image_id}"
}

main() {
    local version
    version="$(resolve_version "${1:-}")"

    check_inputs

    local staging
    staging="$(mktemp -d -t tenkei-kernel-oci-XXXXXX)"
    # shellcheck disable=SC2064
    trap "rm -rf '${staging}'" EXIT

    stage_context "$staging"
    build_image "$version" "$staging"
}

main "$@"
