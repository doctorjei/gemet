#!/usr/bin/env bash
#
# extract-oci — Pure-shell rootfs extractor for OCI image archives
#
# Reads an OCI image archive (the .tar produced by `podman save
# --format=oci-archive` or any OCI-spec-conformant image-layout tarball)
# and writes the merged rootfs to one of three output forms — directory,
# tarball, or qcow2 — without needing podman, umoci, fuse, or root.
#
# Layer composition follows the OCI image spec: layers are applied in
# manifest order; whiteout markers are honored after each layer
# (`.wh.<name>` removes its sibling, `.wh..wh..opq` clears all sibling
# entries that didn't come from the current layer).
#
# Usage:
#   extract-oci.sh [OPTIONS] <oci-archive.tar> <output>
#
# Modes (mutually exclusive — exactly one required; --dir is the default
# if no mode flag is given):
#   --dir            Extract the merged rootfs into <output> (a directory)
#   --tar            Emit a fresh rootfs tarball at <output>
#   --qcow2          Build a bootable single-ext4 qcow2 at <output>
#
# Options:
#   --size <GB>      qcow2 disk size (default: rootfs size + 25% rounded
#                    up to the next GB, minimum 1)
#   --label <s>      ext4 filesystem label for --qcow2 (default: derived
#                    from the input archive name)
#   -h, --help       Show this help
#
# Algorithm (per OCI image-layout spec):
#   1. Untar the archive into a scratch dir (cleaned on exit).
#   2. Read index.json -> first manifest digest -> blobs/sha256/<digest>.
#   3. Iterate manifest .layers[] in order, decompress each by mediaType
#      (gzip, zstd, or uncompressed), extract into a staging tree, then
#      apply whiteouts before moving to the next layer.
#   4. Emit the requested artifact form.
#
# qcow2 mode uses the unprivileged `mkfs.ext4 -d <dir>` path — no loop
# device, no root, no mount. Output is a partition-less single-ext4
# image, matching what rootfs/build-yggdrasil.sh produces. Boot it via
# tenkei's kernel + initramfs with:
#   -append "console=ttyS0 root=/dev/vda rootfstype=ext4"
#
# Requirements:
#   - tar, jq                          (always)
#   - gzip, zstd                       (only if the image has compressed layers)
#   - mkfs.ext4 (e2fsprogs >= 1.43),
#     qemu-img, truncate               (only with --qcow2)
#
set -euo pipefail

# ─── Helpers ──────────────────────────────────────────────────────
info()  { echo -e "\033[1;34m>>>\033[0m $*"; }
warn()  { echo -e "\033[1;33mWARN:\033[0m $*" >&2; }
error() { echo -e "\033[1;31mERROR:\033[0m $*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
Usage: extract-oci.sh [OPTIONS] <oci-archive.tar> <output>

Extract the merged rootfs from an OCI image archive (no podman/umoci/root).

Modes (mutually exclusive — exactly one required; --dir is the default):
  --dir            Extract rootfs into <output> (a directory)
  --tar            Emit a fresh rootfs tarball at <output>
  --qcow2          Build a bootable single-ext4 qcow2 at <output>

Options:
  --size <GB>      qcow2 disk size (default: rootfs size + 25% rounded
                   up to the next GB, minimum 1)
  --label <s>      ext4 filesystem label for --qcow2 (default: derived
                   from the input archive name)
  -h, --help       Show this help

Requires: tar, jq always; gzip/zstd as needed; mkfs.ext4 + qemu-img +
truncate when --qcow2.
USAGE
}

# ─── Parse arguments ──────────────────────────────────────────────
MODE=""
SIZE_GB=""
LABEL=""
ARCHIVE=""
OUTPUT=""

set_mode() {
    [[ -z "$MODE" ]] || error "modes are mutually exclusive (got --$MODE and --$1)"
    MODE="$1"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir)      set_mode dir;    shift ;;
        --tar)      set_mode tar;    shift ;;
        --qcow2)    set_mode qcow2;  shift ;;
        --size)     SIZE_GB="$2";    shift 2 ;;
        --label)    LABEL="$2";      shift 2 ;;
        -h|--help)  usage; exit 0 ;;
        --)         shift; break ;;
        -*)         echo "Error: unknown option: $1" >&2; usage >&2; exit 1 ;;
        *)
            if [[ -z "$ARCHIVE" ]]; then
                ARCHIVE="$1"
            elif [[ -z "$OUTPUT" ]]; then
                OUTPUT="$1"
            else
                echo "Error: unexpected argument: $1" >&2; usage >&2; exit 1
            fi
            shift
            ;;
    esac
done

[[ -n "$ARCHIVE" ]] || { usage >&2; error "missing <oci-archive.tar>"; }
[[ -n "$OUTPUT"  ]] || { usage >&2; error "missing <output>"; }
[[ -f "$ARCHIVE" ]] || error "archive not found: $ARCHIVE"

# Default mode: --dir
[[ -n "$MODE" ]] || MODE=dir

if [[ -n "$SIZE_GB" ]]; then
    [[ "$MODE" == "qcow2" ]] || error "--size only applies with --qcow2"
    [[ "$SIZE_GB" =~ ^[0-9]+$ ]] || error "--size must be a positive integer GB"
    [[ "$SIZE_GB" -ge 1 ]]       || error "--size must be >= 1"
fi

if [[ -n "$LABEL" && "$MODE" != "qcow2" ]]; then
    error "--label only applies with --qcow2"
fi

# ─── Prerequisites ────────────────────────────────────────────────
for tool in tar jq; do
    command -v "$tool" >/dev/null 2>&1 || error "missing required tool: $tool"
done

if [[ "$MODE" == "qcow2" ]]; then
    command -v mkfs.ext4 >/dev/null 2>&1 || error "missing mkfs.ext4 (apt install e2fsprogs)"
    command -v qemu-img  >/dev/null 2>&1 || error "missing qemu-img (apt install qemu-utils)"
    command -v truncate  >/dev/null 2>&1 || error "missing truncate (apt install coreutils)"
fi

# Default qcow2 label from archive basename: strip suffixes, fall back to "rootfs"
if [[ "$MODE" == "qcow2" && -z "$LABEL" ]]; then
    LABEL=$(basename "$ARCHIVE")
    LABEL="${LABEL%.tar}"
    LABEL="${LABEL%.oci}"
    LABEL="${LABEL%-oci}"
    LABEL="${LABEL:-rootfs}"
    # ext4 labels are limited to 16 bytes
    LABEL="${LABEL:0:16}"
fi

# ─── Cleanup ──────────────────────────────────────────────────────
SCRATCH=""
STAGING=""
RAW_IMG=""

cleanup() {
    [[ -n "$SCRATCH" && -d "$SCRATCH" ]] && rm -rf "$SCRATCH" 2>/dev/null || true
    if [[ "$MODE" != "dir" ]]; then
        [[ -n "$STAGING" && -d "$STAGING" ]] && rm -rf "$STAGING" 2>/dev/null || true
    fi
    [[ -n "$RAW_IMG" && -f "$RAW_IMG" ]] && rm -f "$RAW_IMG" 2>/dev/null || true
}
trap cleanup EXIT

# ─── Unpack archive ───────────────────────────────────────────────
SCRATCH=$(mktemp -d "/tmp/extract-oci-scratch.XXXXXX")
info "Unpacking OCI archive into scratch..."
tar -xf "$ARCHIVE" -C "$SCRATCH"

[[ -f "$SCRATCH/oci-layout" ]] || \
    error "missing oci-layout in archive (not an OCI image-layout tarball?)"
[[ -f "$SCRATCH/index.json" ]] || \
    error "missing index.json in archive"

# ─── Resolve manifest blob ────────────────────────────────────────
MANIFEST_DIGEST=$(jq -r '.manifests[0].digest // empty' "$SCRATCH/index.json")
[[ -n "$MANIFEST_DIGEST" ]] || error "index.json has no manifests[0].digest"
case "$MANIFEST_DIGEST" in
    sha256:*) ;;
    *) error "unsupported manifest digest algorithm: $MANIFEST_DIGEST (expected sha256:)" ;;
esac
MANIFEST_HASH="${MANIFEST_DIGEST#sha256:}"
MANIFEST_BLOB="$SCRATCH/blobs/sha256/$MANIFEST_HASH"
[[ -f "$MANIFEST_BLOB" ]] || error "manifest blob not found: $MANIFEST_BLOB"

# Some archives wrap the per-platform manifest inside an image index.
# If mediaType is an index/list, descend one level into manifests[0].
TOP_MEDIA=$(jq -r '.mediaType // empty' "$MANIFEST_BLOB")
case "$TOP_MEDIA" in
    application/vnd.oci.image.index.v1+json|application/vnd.docker.distribution.manifest.list.v2+json)
        info "Top-level blob is an image index — descending."
        INNER_DIGEST=$(jq -r '.manifests[0].digest // empty' "$MANIFEST_BLOB")
        [[ -n "$INNER_DIGEST" ]] || error "image index has no inner manifest"
        case "$INNER_DIGEST" in
            sha256:*) ;;
            *) error "unsupported inner digest algorithm: $INNER_DIGEST" ;;
        esac
        MANIFEST_HASH="${INNER_DIGEST#sha256:}"
        MANIFEST_BLOB="$SCRATCH/blobs/sha256/$MANIFEST_HASH"
        [[ -f "$MANIFEST_BLOB" ]] || error "inner manifest blob not found: $MANIFEST_BLOB"
        ;;
esac

LAYER_COUNT=$(jq -r '.layers | length' "$MANIFEST_BLOB")
[[ "$LAYER_COUNT" =~ ^[0-9]+$ ]] && [[ "$LAYER_COUNT" -gt 0 ]] || \
    error "manifest has no layers (or layers field is malformed)"
info "Manifest has $LAYER_COUNT layer(s)."

# ─── Staging dir for --dir / --qcow2 / multi-layer --tar ──────────
if [[ "$MODE" == "dir" ]]; then
    # For --dir, the output IS the staging dir; create it.
    mkdir -p "$OUTPUT"
    STAGING="$OUTPUT"
else
    STAGING=$(mktemp -d "/tmp/extract-oci-staging.XXXXXX")
fi

# ─── Layer extraction helpers ─────────────────────────────────────
decompressor_for() {
    # Echo a command that decompresses stdin -> stdout for the given mediaType
    # and blob path (used to sniff when mediaType is unknown). Empty stdout
    # means "uncompressed; cat the blob through tar directly".
    local media="$1" blob="$2"
    case "$media" in
        application/vnd.oci.image.layer.v1.tar+gzip| \
        application/vnd.docker.image.rootfs.diff.tar.gzip)
            command -v gzip >/dev/null 2>&1 || error "layer is gzip but gzip is missing"
            echo "gzip -dc"
            ;;
        application/vnd.oci.image.layer.v1.tar+zstd)
            command -v zstd >/dev/null 2>&1 || error "layer is zstd but zstd is missing"
            echo "zstd -dc"
            ;;
        application/vnd.oci.image.layer.v1.tar)
            echo ""
            ;;
        *)
            # Unknown / missing mediaType — sniff with `file` if available,
            # otherwise let tar autodetect via its decompression flag.
            local sniff=""
            if command -v file >/dev/null 2>&1; then
                sniff=$(file --mime-type -b "$blob" 2>/dev/null || true)
            fi
            case "$sniff" in
                application/gzip|application/x-gzip)
                    command -v gzip >/dev/null 2>&1 || \
                        error "layer sniffed as gzip but gzip missing"
                    echo "gzip -dc"
                    ;;
                application/zstd|application/x-zstd)
                    command -v zstd >/dev/null 2>&1 || \
                        error "layer sniffed as zstd but zstd missing"
                    echo "zstd -dc"
                    ;;
                application/x-tar|"")
                    # Trust tar's auto-detection (-a) as a final fallback.
                    echo "AUTO"
                    ;;
                *)
                    warn "layer mediaType '$media' / sniff '$sniff' unrecognized; trying tar -a"
                    echo "AUTO"
                    ;;
            esac
            ;;
    esac
}

apply_whiteouts() {
    # OCI whiteout convention:
    #   .wh..wh..opq  → opaque marker; remove all sibling entries that
    #                    weren't extracted by THIS layer (we approximate
    #                    by removing all siblings other than the marker
    #                    itself and entries from the just-extracted list).
    #   .wh.<name>    → remove the sibling named <name>.
    # Caller passes the staging root and the path of a per-layer file
    # listing the entries the current layer extracted (one path per line,
    # relative to the staging root, leading ./ stripped).
    local root="$1" extracted_list="$2"

    # Pass 1: opaque markers. For each .wh..wh..opq, list the parent dir's
    # children, keep anything the current layer placed there, drop the rest.
    while IFS= read -r -d '' opq; do
        local dir
        dir=$(dirname "$opq")
        # Build a set of "kept" basenames from the extracted list.
        local layer_dir_rel="${dir#"$root"}"
        layer_dir_rel="${layer_dir_rel#/}"
        local keep_file
        keep_file=$(mktemp "$SCRATCH/opq-keep.XXXXXX")
        if [[ -z "$layer_dir_rel" ]]; then
            awk -F/ 'NF==1{print $1} NF>1{print $1}' "$extracted_list" \
                | sort -u > "$keep_file"
        else
            local depth
            depth=$(awk -F/ '{print NF}' <<<"$layer_dir_rel")
            local child_field=$((depth + 1))
            awk -F/ -v p="$layer_dir_rel/" -v cf="$child_field" \
                'index($0, p) == 1 && NF >= cf { print $cf }' \
                "$extracted_list" | sort -u > "$keep_file"
        fi

        # Sweep siblings.
        local entry base
        for entry in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
            [[ -e "$entry" || -L "$entry" ]] || continue
            base=$(basename "$entry")
            [[ "$base" == ".wh..wh..opq" ]] && continue
            if ! grep -Fxq "$base" "$keep_file"; then
                rm -rf "$entry"
            fi
        done
        rm -f "$opq" "$keep_file"
    done < <(find "$root" -type f -name '.wh..wh..opq' -print0 2>/dev/null)

    # Pass 2: per-entry whiteouts.
    while IFS= read -r -d '' wh; do
        local dir base target
        dir=$(dirname "$wh")
        base=$(basename "$wh")
        target="$dir/${base#.wh.}"
        rm -rf "$target"
        rm -f "$wh"
    done < <(find "$root" -name '.wh.*' ! -name '.wh..wh..opq' -print0 2>/dev/null)
}

extract_layer() {
    local idx="$1" digest="$2" media="$3"
    case "$digest" in
        sha256:*) ;;
        *) error "layer $idx: unsupported digest algorithm: $digest" ;;
    esac
    local hash="${digest#sha256:}"
    local blob="$SCRATCH/blobs/sha256/$hash"
    [[ -f "$blob" ]] || error "layer $idx blob missing: $blob"

    local cmd
    cmd=$(decompressor_for "$media" "$blob")

    info "Layer $((idx + 1))/$LAYER_COUNT: ${digest:0:19}... (${media:-unknown})"

    local list
    list=$(mktemp "$SCRATCH/layer-$idx.list.XXXXXX")

    # Tar -v writes extracted paths to stderr; we want them on stdout to
    # capture into $list. Use --verbose with --to-stdout? No — easier:
    # extract first, then enumerate the blob's contents with `tar -t`.
    if [[ -z "$cmd" ]]; then
        tar -xf "$blob" -C "$STAGING"
        tar -tf "$blob" > "$list"
    elif [[ "$cmd" == "AUTO" ]]; then
        tar -xaf "$blob" -C "$STAGING"
        tar -taf "$blob" > "$list"
    else
        $cmd < "$blob" | tar -xf - -C "$STAGING"
        $cmd < "$blob" | tar -tf - > "$list"
    fi

    # Normalize: strip leading "./" and trailing "/" so the list matches
    # what apply_whiteouts compares against.
    sed -i -e 's|^\./||' -e 's|/$||' "$list"

    apply_whiteouts "$STAGING" "$list"
    rm -f "$list"
}

# ─── Walk layers ──────────────────────────────────────────────────
LAYER_DIGESTS=$(jq -r '.layers[].digest' "$MANIFEST_BLOB")
LAYER_MEDIA=$(jq -r '.layers[].mediaType // ""' "$MANIFEST_BLOB")

i=0
paste <(echo "$LAYER_DIGESTS") <(echo "$LAYER_MEDIA") | \
while IFS=$'\t' read -r digest media; do
    extract_layer "$i" "$digest" "$media"
    i=$((i + 1))
done

# ─── Emit artifact ────────────────────────────────────────────────
case "$MODE" in
    dir)
        info "Rootfs extracted to: $OUTPUT"
        info "Size: $(du -sh "$OUTPUT" 2>/dev/null | awk '{print $1}')"
        ;;
    tar)
        info "Writing rootfs tarball to: $OUTPUT"
        tar -cf "$OUTPUT" -C "$STAGING" .
        info "Size: $(du -h "$OUTPUT" 2>/dev/null | awk '{print $1}')"
        ;;
    qcow2)
        if [[ -z "$SIZE_GB" ]]; then
            STAGING_BYTES=$(du -sb "$STAGING" | awk '{print $1}')
            # Add 25% headroom, round up to GB, minimum 1.
            SIZE_GB=$(( (STAGING_BYTES * 5 / 4 + 1024*1024*1024 - 1) / (1024*1024*1024) ))
            [[ "$SIZE_GB" -lt 1 ]] && SIZE_GB=1
            info "Auto-sized qcow2: ${SIZE_GB}G (rootfs $(du -sh "$STAGING" | awk '{print $1}'))"
        fi

        RAW_IMG=$(mktemp "/tmp/extract-oci-raw.XXXXXX.raw")
        info "Allocating ${SIZE_GB}G raw image..."
        truncate -s "${SIZE_GB}G" "$RAW_IMG"

        info "Formatting ext4 (label=$LABEL) and populating from staging..."
        mkfs.ext4 -q -F -L "$LABEL" \
            -E lazy_itable_init=0,lazy_journal_init=0 \
            -d "$STAGING" "$RAW_IMG"

        info "Converting raw → compressed qcow2 at $OUTPUT..."
        qemu-img convert -c -f raw -O qcow2 "$RAW_IMG" "$OUTPUT"
        rm -f "$RAW_IMG"
        RAW_IMG=""

        info "qcow2 size: $(du -h "$OUTPUT" 2>/dev/null | awk '{print $1}') (${SIZE_GB}G virtual)"
        ;;
esac
