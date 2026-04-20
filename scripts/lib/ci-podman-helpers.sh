#!/usr/bin/env bash
#
# ci-podman-helpers.sh — shared helpers for Tier 2 CI scripts
#
# Sourced by (at minimum):
#   - scripts/ci-bifrost-test.sh
#   - scripts/ci-canopy-test.sh
#
# NOT sourced by scripts/ci-systemd-test.sh — that script predates this
# helper file and was left untouched on purpose (its logic is stable
# and already battle-tested through v1.2.0).
#
# Why this exists: during the v1.2.0 release we learned the hard way
# that Tier 2 scripts must NOT unconditionally `podman rmi` the image
# they tested — in the release pipeline the build step imports the
# image into the store first, and the Tier 2 `podman load` is a no-op.
# If cleanup rmi's regardless, the downstream GHCR push step finds no
# image to tag. See commits 98b9a03 and c3847ac.
#
# This file provides three small helpers that together implement the
# "load, run, clean only what we added" pattern:
#
#   cih_snapshot_images      — snapshot image list before load
#   cih_load_image <archive> — podman load, parse image ref, set
#                               $CIH_IMAGE + $CIH_IMAGE_ADDED based on
#                               whether the ref pre-existed
#   cih_cleanup_image        — rmi the image, but only if we added it
#
# Call site idiom (see ci-bifrost-test.sh / ci-canopy-test.sh):
#
#   source scripts/lib/ci-podman-helpers.sh
#   cih_snapshot_images
#   if ! cih_load_image "$OCI_ARCHIVE"; then
#       fail "podman load failed"
#   fi
#   trap cih_cleanup_image EXIT   # callers usually trap their own combined cleanup
#
# Design decision: Option A (shared helper) over Option B (copy-paste)
# — extract is clean (~30 lines), two callers today, more likely to
# come (canopy-derived variants, etc.). A single correct implementation
# beats two near-identical copies drifting apart.

# Shared state. Callers read these after cih_load_image returns 0.
CIH_PRE_LOAD_IMAGES=""   # newline-separated Repository:Tag list
CIH_IMAGE=""             # parsed image ref (non-empty iff load succeeded)
CIH_IMAGE_ADDED=0        # 1 iff load genuinely added the image (not a no-op)

# Snapshot the podman image list. Must be called BEFORE cih_load_image
# so we can tell whether the load added a new image or was a no-op on
# a pre-existing one.
cih_snapshot_images() {
    CIH_PRE_LOAD_IMAGES=$(podman images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null || true)
}

# Load an OCI archive, parse the image name, and record whether we
# genuinely added the image. Returns 0 on success, non-zero if the
# load command itself failed. Prints podman's stderr on failure so
# the caller can surface it.
#
# Usage: cih_load_image /path/to/foo-oci.tar
cih_load_image() {
    local archive="$1"
    local load_out
    if ! load_out=$(podman load -i "$archive" 2>&1); then
        echo "$load_out" >&2
        return 1
    fi
    # `podman load` prints lines like:
    #   Loaded image: localhost/bifrost:1.3.0
    #   Loaded image(s): localhost/bifrost:1.3.0
    # Take the last such line's final field.
    CIH_IMAGE=$(echo "$load_out" | awk '/Loaded image/ {img=$NF} END{print img}')
    if [[ -z "$CIH_IMAGE" ]]; then
        # Fallback: look for any tagged-image-looking token.
        CIH_IMAGE=$(echo "$load_out" | grep -oE '[a-zA-Z0-9._/-]+:[a-zA-Z0-9._-]+' | tail -1)
    fi
    if [[ -z "$CIH_IMAGE" ]]; then
        echo "$load_out" >&2
        echo "ERROR: could not parse loaded image name from podman load output" >&2
        return 1
    fi
    if echo "$CIH_PRE_LOAD_IMAGES" | grep -Fxq "$CIH_IMAGE"; then
        CIH_IMAGE_ADDED=0
    else
        CIH_IMAGE_ADDED=1
    fi
    return 0
}

# Remove the loaded image, but only if we added it. Safe to call
# multiple times / from traps. Does NOT stop/rm any containers —
# callers own their own container lifecycle.
cih_cleanup_image() {
    if (( CIH_IMAGE_ADDED == 1 )) && [[ -n "$CIH_IMAGE" ]]; then
        podman rmi -f "$CIH_IMAGE" >/dev/null 2>&1 || true
    fi
}
