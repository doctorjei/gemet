#!/usr/bin/env bash
#
# bifrost-sync-sshkeys.sh — Merge /etc/bifrost/authorized_keys into
# /root/.ssh/authorized_keys, idempotently and non-destructively.
#
# Invocation: bifrost-sshkey-sync.service (systemd oneshot), once per boot.
# Contract: orchestrators (kento, droste, humans) stage pubkey lines at
# $SOURCE before starting the container/VM. This script appends any line
# from $SOURCE not already present verbatim in $TARGET. Existing keys in
# $TARGET are never removed or rewritten; the user may add their own keys
# and they will be preserved across boots.
#
set -euo pipefail

SOURCE="${BIFROST_SSHKEY_SOURCE:-/etc/bifrost/authorized_keys}"
TARGET="${BIFROST_SSHKEY_TARGET:-/root/.ssh/authorized_keys}"
TARGET_DIR="$(dirname "$TARGET")"

# Defense in depth — the systemd unit has ConditionPathExists, but this
# script should also be safe to invoke directly.
if [[ ! -f "$SOURCE" ]]; then
    exit 0
fi

# Create target dir if missing; don't clobber perms on an existing dir.
if [[ ! -d "$TARGET_DIR" ]]; then
    install -d -m 0700 "$TARGET_DIR"
fi

if [[ ! -f "$TARGET" ]]; then
    touch "$TARGET"
    chmod 0600 "$TARGET"
fi

# Read $SOURCE line by line. The `|| [[ -n "$line" ]]` guard catches a
# final line with no trailing newline (which `read` would otherwise drop).
added=0
while IFS= read -r line || [[ -n "$line" ]]; do
    # Trim trailing whitespace (spaces, tabs, CR)
    line="${line%"${line##*[![:space:]]}"}"

    # Skip empty lines and comments
    [[ -z "$line" ]] && continue
    [[ "$line" == \#* ]] && continue

    # Exact-line, fixed-string check. The `--` guards against lines that
    # happen to begin with `-` (would otherwise be mis-parsed as options).
    if ! grep -Fx -q -- "$line" "$TARGET"; then
        printf '%s\n' "$line" >> "$TARGET"
        echo "Added key: ${line:0:40}..."
        added=$((added + 1))
    fi
done < "$SOURCE"

if [[ $added -eq 0 ]]; then
    echo "No new keys to add (source already synced)."
fi

exit 0
