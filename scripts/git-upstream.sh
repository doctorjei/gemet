#!/usr/bin/env bash
#
# git-upstream — Manage upstream subtree imports from kata-containers
#
# Imports tools/osbuilder and tools/packaging/kernel from the
# kata-containers monorepo as git subtrees, and keeps them updated.
#
# Usage:
#   git-upstream setup    — first-time import of both subtrees
#   git-upstream fetch    — fetch latest from upstream (no merge)
#   git-upstream pull     — fetch + merge upstream changes
#   git-upstream status   — show current upstream commit info
#
# Run from the root of your tenkei repository.
#
set -euo pipefail

# ─── Configuration ─────────────────────────────────────────────────

UPSTREAM_REPO="https://github.com/kata-containers/kata-containers.git"
UPSTREAM_REMOTE="kata-upstream"
UPSTREAM_BRANCH="main"

# What we import and where it lands locally
declare -A SUBTREES=(
    [upstream/osbuilder]="tools/osbuilder"
    [upstream/kernel]="tools/packaging/kernel"
)

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/tenkei-upstream"
CLONE_DIR="${CACHE_DIR}/kata-containers"

# ─── Helpers ───────────────────────────────────────────────────────

info()  { echo -e "\033[1;34m>>>\033[0m $*"; }
warn()  { echo -e "\033[1;33mWARN:\033[0m $*" >&2; }
error() { echo -e "\033[1;31mERROR:\033[0m $*" >&2; exit 1; }

check_git_repo() {
    git rev-parse --is-inside-work-tree &>/dev/null || \
        error "Not inside a git repository"
}

# Maintain a shallow clone of the kata monorepo for splitting
ensure_clone() {
    if [[ -d "$CLONE_DIR/.git" ]]; then
        info "Updating cached kata clone..."
        git -C "$CLONE_DIR" fetch origin "$UPSTREAM_BRANCH" --depth=1
        git -C "$CLONE_DIR" checkout FETCH_HEAD --quiet
    else
        info "Cloning kata-containers (shallow)..."
        mkdir -p "$CACHE_DIR"
        git clone --depth=1 --branch "$UPSTREAM_BRANCH" \
            "$UPSTREAM_REPO" "$CLONE_DIR"
    fi
}

# Split a subdirectory out of the cached clone into a temporary branch
split_subtree() {
    local upstream_path="$1"
    local branch_name="$2"

    info "Splitting ${upstream_path} → ${branch_name}..."

    # We can't use git subtree split on a shallow clone.
    # Instead, create a synthetic commit with just the subtree contents.
    local tree_hash
    tree_hash=$(
        git -C "$CLONE_DIR" ls-tree HEAD -- "$upstream_path" \
            | head -1 | awk '{print $3}'
    )

    if [[ -z "$tree_hash" ]]; then
        error "Path '${upstream_path}' not found in upstream"
    fi

    # Import objects from the clone into our repo
    local alt_objects="${CLONE_DIR}/.git/objects"
    local our_git_dir
    our_git_dir=$(git rev-parse --git-dir)

    # Use git fetch with a refspec to bring objects in
    git fetch "$CLONE_DIR" HEAD --quiet 2>/dev/null || true

    # Create a commit containing just this subtree
    local upstream_sha
    upstream_sha=$(git -C "$CLONE_DIR" rev-parse --short HEAD)
    local upstream_date
    upstream_date=$(git -C "$CLONE_DIR" log -1 --format=%ci HEAD)

    local commit_hash
    commit_hash=$(
        git commit-tree "$tree_hash" -m \
            "upstream: ${upstream_path} @ ${upstream_sha} (${upstream_date})"
    )

    # Point a local branch at this commit
    git branch -f "$branch_name" "$commit_hash"
    info "Branch '${branch_name}' → ${upstream_sha}"
}

# ─── Commands ──────────────────────────────────────────────────────

cmd_setup() {
    check_git_repo
    ensure_clone

    for local_prefix in $(printf '%s\n' "${!SUBTREES[@]}" | sort); do
        local upstream_path="${SUBTREES[$local_prefix]}"
        local branch_name="upstream/$(basename "$local_prefix")"

        if [[ -d "$local_prefix" ]]; then
            warn "${local_prefix} already exists — skipping"
            continue
        fi

        split_subtree "$upstream_path" "_${branch_name}"

        info "Adding subtree at ${local_prefix}..."
        git subtree add \
            --prefix="$local_prefix" \
            "_${branch_name}" \
            --squash \
            -m "Import ${upstream_path} from kata-containers"

        git branch -D "_${branch_name}" 2>/dev/null || true
    done

    info "Setup complete."
    echo ""
    echo "Imported subtrees:"
    for local_prefix in $(printf '%s\n' "${!SUBTREES[@]}" | sort); do
        echo "  ${SUBTREES[$local_prefix]} → ${local_prefix}"
    done
}

cmd_fetch() {
    check_git_repo
    ensure_clone

    local upstream_sha
    upstream_sha=$(git -C "$CLONE_DIR" rev-parse --short HEAD)
    local upstream_date
    upstream_date=$(git -C "$CLONE_DIR" log -1 --format=%ci HEAD)

    echo ""
    echo "Latest upstream: ${upstream_sha} (${upstream_date})"
    echo "  Subject: $(git -C "$CLONE_DIR" log -1 --format=%s HEAD)"
    echo ""
    echo "Run 'git-upstream pull' to merge changes."
}

cmd_pull() {
    check_git_repo
    ensure_clone

    for local_prefix in $(printf '%s\n' "${!SUBTREES[@]}" | sort); do
        local upstream_path="${SUBTREES[$local_prefix]}"
        local branch_name="upstream/$(basename "$local_prefix")"

        if [[ ! -d "$local_prefix" ]]; then
            warn "${local_prefix} does not exist — run 'setup' first"
            continue
        fi

        split_subtree "$upstream_path" "_${branch_name}"

        info "Merging upstream changes into ${local_prefix}..."
        git subtree merge \
            --prefix="$local_prefix" \
            "_${branch_name}" \
            --squash \
            -m "Update ${upstream_path} from kata-containers" \
            || warn "Merge had conflicts — resolve manually"

        git branch -D "_${branch_name}" 2>/dev/null || true
    done

    info "Pull complete."
}

cmd_status() {
    check_git_repo

    echo "Subtree status:"
    echo ""
    for local_prefix in $(printf '%s\n' "${!SUBTREES[@]}" | sort); do
        local upstream_path="${SUBTREES[$local_prefix]}"
        if [[ -d "$local_prefix" ]]; then
            local last_merge
            last_merge=$(
                git log --oneline --grep="kata-containers" \
                    -- "$local_prefix" | head -1
            )
            echo "  ${local_prefix} (← ${upstream_path})"
            echo "    Last sync: ${last_merge:-unknown}"
        else
            echo "  ${local_prefix} — not imported"
        fi
    done

    if [[ -d "$CLONE_DIR/.git" ]]; then
        echo ""
        echo "Cached clone:"
        echo "  $(git -C "$CLONE_DIR" rev-parse --short HEAD) \
($(git -C "$CLONE_DIR" log -1 --format=%ci HEAD))"
    fi
}

# ─── Main ──────────────────────────────────────────────────────────

usage() {
    cat <<'USAGE'
Usage: git-upstream <command>

Commands:
  setup    — first-time import of upstream subtrees
  fetch    — fetch latest from upstream (no merge)
  pull     — fetch + merge upstream changes
  status   — show current upstream commit info
USAGE
    exit "${1:-1}"
}

case "${1:-}" in
    setup)      cmd_setup ;;
    fetch)      cmd_fetch ;;
    pull)       cmd_pull ;;
    status)     cmd_status ;;
    -h|--help)  usage 0 ;;
    *)          usage ;;
esac
