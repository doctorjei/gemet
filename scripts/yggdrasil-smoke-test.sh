#!/usr/bin/env bash
#
# yggdrasil-smoke-test — Self-contained boot verification for Yggdrasil artifacts
#
# Boots a Yggdrasil qcow2 disk image with tenkei's kernel + initramfs and
# watches the serial console for boot-success markers. Designed to be scp'd
# alongside the artifacts to any Linux machine — no dependency on the tenkei
# repo. Exits 0 on a fully-booted VM, 1 on boot failure, 2 on pre-flight
# failure.
#
# Usage:
#   yggdrasil-smoke-test.sh [options]
#
# Options:
#   --qcow2 <path>    qcow2 disk image (default: ./yggdrasil-*.qcow2 in script dir)
#   --kernel <path>   Path to vmlinuz   (default: ./vmlinuz in script dir)
#   --initrd <path>   Path to initramfs (default: ./gemet-initramfs.img in script dir)
#   --memory <MB>     VM memory in MB   (default: 512)
#   --timeout <sec>   Boot wait timeout (default: 90)
#   --no-kvm          Force TCG (default: auto-detect /dev/kvm)
#   --keep            Don't shut down on success; leave VM running for inspection
#   --log <path>      Serial console log path (default: ./yggdrasil-smoke-<ts>.log)
#   -h, --help        Show this help
#
# The cmdline passed to the kernel is:
#   console=ttyS0 root=/dev/vda rootfstype=ext4
#
# Boot-success checkpoints (watched on serial):
#   - "Linux version"        kernel started
#   - "tenkei: " or          initramfs ran
#     "switch_root"
#   - "systemd[1]: "         PID 1 systemd is up
#   - "Reached target"       at least one systemd target reached
#   - "login:"               serial-getty prompted (final marker)
#
# Hard-fail conditions:
#   - "Kernel panic"
#   - "Dropping to emergency shell"
#   - Total timeout exceeded with no "login:" prompt
#
# Requirements:
#   - qemu-system-x86_64
#   - KVM access (/dev/kvm) recommended; --no-kvm for software emulation
#   - socat or nc (for graceful shutdown via QEMU monitor); not strictly required
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Helpers ------------------------------------------------------
info()  { echo -e "\033[1;34m>>>\033[0m $*"; }
warn()  { echo -e "\033[1;33mWARN:\033[0m $*" >&2; }
error() { echo -e "\033[1;31mERROR:\033[0m $*" >&2; }
die()   { error "$*"; exit "${2:-1}"; }

usage() {
    cat <<'USAGE'
Usage: yggdrasil-smoke-test.sh [options]

Boots a Yggdrasil qcow2 image with tenkei's kernel/initramfs and verifies it
reaches a login prompt by pattern-matching the serial console.

Options:
  --qcow2 <path>    qcow2 disk image (default: ./yggdrasil-*.qcow2 in script dir)
  --kernel <path>   Path to vmlinuz   (default: ./vmlinuz in script dir)
  --initrd <path>   Path to initramfs (default: ./gemet-initramfs.img in script dir)
  --memory <MB>     VM memory in MB   (default: 512)
  --timeout <sec>   Boot wait timeout (default: 90)
  --no-kvm          Force TCG (default: auto-detect /dev/kvm)
  --keep            Don't shut down on success; leave VM running for inspection
  --log <path>      Serial console log path (default: ./yggdrasil-smoke-<ts>.log)
  -h, --help        Show this help

Exit codes:
  0  Full boot success (all checkpoints reached)
  1  Boot failure (kernel panic, emergency shell, or timeout)
  2  Pre-flight failure (missing artifact, missing qemu, etc.)
USAGE
    exit "${1:-0}"
}

# --- Defaults -----------------------------------------------------

QCOW2=""
KERNEL="$SCRIPT_DIR/vmlinuz"
INITRD="$SCRIPT_DIR/gemet-initramfs.img"
MEMORY=512
TIMEOUT=90
USE_KVM=true
KEEP=false
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$SCRIPT_DIR/yggdrasil-smoke-${TIMESTAMP}.log"

# --- Parse arguments ---------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --qcow2)   QCOW2="$2"; shift 2 ;;
        --kernel)  KERNEL="$2"; shift 2 ;;
        --initrd)  INITRD="$2"; shift 2 ;;
        --memory)  MEMORY="$2"; shift 2 ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        --no-kvm)  USE_KVM=false; shift ;;
        --keep)    KEEP=true; shift ;;
        --log)     LOG="$2"; shift 2 ;;
        -h|--help) usage 0 ;;
        *)         echo "Error: unknown option: $1" >&2; usage 2 ;;
    esac
done

# Default qcow2: first match of yggdrasil-*.qcow2 in script dir
if [[ -z "$QCOW2" ]]; then
    shopt -s nullglob
    candidates=("$SCRIPT_DIR"/yggdrasil-*.qcow2)
    shopt -u nullglob
    if [[ ${#candidates[@]} -gt 0 ]]; then
        QCOW2="${candidates[0]}"
    else
        QCOW2="$SCRIPT_DIR/yggdrasil.qcow2"  # placeholder for the error message
    fi
fi

# --- Pre-flight checks -------------------------------------------

preflight_fail() {
    error "$*"
    exit 2
}

# qemu binary
if ! command -v qemu-system-x86_64 &>/dev/null; then
    preflight_fail "qemu-system-x86_64 not found. Install: apt install qemu-system-x86"
fi

# Artifacts exist
[[ -f "$QCOW2" ]]  || preflight_fail "qcow2 not found: $QCOW2 (use --qcow2 PATH)"
[[ -f "$KERNEL" ]] || preflight_fail "kernel not found: $KERNEL (use --kernel PATH)"
[[ -f "$INITRD" ]] || preflight_fail "initramfs not found: $INITRD (use --initrd PATH)"

# Sanity bounds (size in bytes via stat)
file_size() {
    # POSIX-portable-ish; stat varies between GNU and BSD
    if stat -c '%s' "$1" &>/dev/null; then
        stat -c '%s' "$1"
    else
        stat -f '%z' "$1"
    fi
}

QCOW2_SIZE="$(file_size "$QCOW2")"
KERNEL_SIZE="$(file_size "$KERNEL")"
INITRD_SIZE="$(file_size "$INITRD")"

[[ "$QCOW2_SIZE"  -gt 0 ]] || preflight_fail "qcow2 is empty: $QCOW2"
[[ "$KERNEL_SIZE" -gt 0 ]] || preflight_fail "kernel is empty: $KERNEL"
[[ "$INITRD_SIZE" -gt 0 ]] || preflight_fail "initramfs is empty: $INITRD"

[[ "$QCOW2_SIZE"  -gt $((50 * 1024 * 1024)) ]] || \
    preflight_fail "qcow2 suspiciously small (<50 MB): $QCOW2 ($QCOW2_SIZE bytes)"
[[ "$KERNEL_SIZE" -gt $((1 * 1024 * 1024)) ]] || \
    preflight_fail "kernel suspiciously small (<1 MB): $KERNEL ($KERNEL_SIZE bytes)"
[[ "$INITRD_SIZE" -gt $((100 * 1024)) ]] || \
    preflight_fail "initramfs suspiciously small (<100 KB): $INITRD ($INITRD_SIZE bytes)"

# KVM
if $USE_KVM; then
    if [[ ! -e /dev/kvm ]]; then
        warn "/dev/kvm not found — falling back to TCG (this will be slow)"
        warn "Pass --no-kvm to silence this warning"
        USE_KVM=false
    elif [[ ! -r /dev/kvm ]]; then
        warn "/dev/kvm exists but is not readable — falling back to TCG (this will be slow)"
        warn "Add yourself to the 'kvm' group, or pass --no-kvm to silence this warning"
        USE_KVM=false
    fi
fi

# Shutdown helper detection (not fatal)
SHUTDOWN_HELPER=""
if command -v socat &>/dev/null; then
    SHUTDOWN_HELPER="socat"
elif command -v nc &>/dev/null; then
    SHUTDOWN_HELPER="nc"
fi

# --- Prepare runtime state ---------------------------------------

TMPDIR_RUN="$(mktemp -d -t yggdrasil-smoke.XXXXXX)"
MONITOR_SOCK="$TMPDIR_RUN/monitor.sock"
QEMU_PID=""

# Ensure log file exists & is empty (so tail -F works from line 1)
: > "$LOG"

# --- Cleanup trap ------------------------------------------------

cleanup() {
    local rc=$?
    set +e
    if [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
        if $KEEP && [[ $rc -eq 0 ]]; then
            : # leave it running for the user
        else
            kill "$QEMU_PID" 2>/dev/null
            # Give it a moment, then SIGKILL
            for _ in 1 2 3 4 5; do
                kill -0 "$QEMU_PID" 2>/dev/null || break
                sleep 1
            done
            kill -9 "$QEMU_PID" 2>/dev/null
        fi
    fi
    if [[ -d "$TMPDIR_RUN" ]]; then
        if $KEEP && [[ $rc -eq 0 ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
            : # keep monitor socket around for the user
        else
            rm -rf "$TMPDIR_RUN"
        fi
    fi
}
trap cleanup EXIT

# --- Show plan ---------------------------------------------------

info "Yggdrasil smoke test"
info "  qcow2:    $QCOW2 ($((QCOW2_SIZE / 1024 / 1024)) MB)"
info "  kernel:   $KERNEL ($((KERNEL_SIZE / 1024)) KB)"
info "  initrd:   $INITRD ($((INITRD_SIZE / 1024)) KB)"
info "  memory:   ${MEMORY} MB"
info "  timeout:  ${TIMEOUT}s"
info "  KVM:      $USE_KVM"
info "  keep:     $KEEP"
info "  log:      $LOG"
info "  monitor:  $MONITOR_SOCK"
info ""

# --- Build QEMU cmdline ------------------------------------------

kvm_args=()
if $USE_KVM; then
    kvm_args=(-enable-kvm -cpu host)
fi

info "Launching QEMU in background..."

qemu-system-x86_64 \
    -machine q35 \
    "${kvm_args[@]}" \
    -m "$MEMORY" \
    -kernel "$KERNEL" \
    -initrd "$INITRD" \
    -drive "file=${QCOW2},format=qcow2,if=virtio" \
    -netdev user,id=net0 \
    -device virtio-net-pci,netdev=net0 \
    -nographic \
    -serial "file:$LOG" \
    -monitor "unix:${MONITOR_SOCK},server,nowait" \
    -append "console=ttyS0 root=/dev/vda rootfstype=ext4" \
    >/dev/null 2>&1 &

QEMU_PID=$!
info "QEMU PID: $QEMU_PID"

# Brief sleep to let QEMU come up before we start tailing
sleep 1

if ! kill -0 "$QEMU_PID" 2>/dev/null; then
    error "QEMU failed to start (exited immediately). Last log lines:"
    tail -20 "$LOG" >&2 || true
    exit 1
fi

# --- Watch serial log for checkpoints ----------------------------

# Checkpoint flags
CK_KERNEL=false
CK_INITRAMFS=false
CK_SYSTEMD=false
CK_TARGET=false
CK_LOGIN=false

mark_checkpoint() {
    case "$1" in
        kernel)    $CK_KERNEL    || { info "[checkpoint] kernel started ('Linux version' seen)";          CK_KERNEL=true; } ;;
        initramfs) $CK_INITRAMFS || { info "[checkpoint] initramfs ran ('tenkei:' or 'switch_root' seen)"; CK_INITRAMFS=true; } ;;
        systemd)   $CK_SYSTEMD   || { info "[checkpoint] systemd PID 1 active ('systemd[1]:' seen)";       CK_SYSTEMD=true; } ;;
        target)    $CK_TARGET    || { info "[checkpoint] systemd target reached ('Reached target' seen)";  CK_TARGET=true; } ;;
        login)     $CK_LOGIN     || { info "[checkpoint] login prompt reached ('login:' seen)";            CK_LOGIN=true; } ;;
    esac
}

dump_tail() {
    local n="${1:-20}"
    echo "----- last $n lines of serial log -----" >&2
    tail -n "$n" "$LOG" >&2 || true
    echo "---------------------------------------" >&2
}

start_time=$(date +%s)
kernel_deadline=$((start_time + 10))
boot_deadline=$((start_time + TIMEOUT))

info "Watching serial log (timeout ${TIMEOUT}s)..."

while true; do
    # QEMU still alive?
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        error "QEMU exited unexpectedly during boot watch."
        dump_tail 30
        FAIL_REASON="qemu-died"
        break
    fi

    # Read current log content
    if [[ -s "$LOG" ]]; then
        log_content="$(cat "$LOG" 2>/dev/null || true)"
    else
        log_content=""
    fi

    # Hard-fail patterns first
    if grep -q -- "Kernel panic" <<<"$log_content"; then
        error "Kernel panic detected."
        dump_tail 20
        FAIL_REASON="kernel-panic"
        break
    fi
    if grep -q -- "Dropping to emergency shell" <<<"$log_content"; then
        error "Initramfs dropped to emergency shell."
        dump_tail 20
        FAIL_REASON="emergency-shell"
        break
    fi

    # Checkpoints
    grep -q -- "Linux version" <<<"$log_content"  && mark_checkpoint kernel
    if grep -qE "^tenkei: |switch_root" <<<"$log_content"; then
        mark_checkpoint initramfs
    fi
    grep -q -- "systemd\[1\]:" <<<"$log_content"  && mark_checkpoint systemd
    grep -q -- "Reached target" <<<"$log_content" && mark_checkpoint target
    grep -q -- "login:" <<<"$log_content"         && mark_checkpoint login

    if $CK_LOGIN; then
        info "All boot checkpoints reached."
        FAIL_REASON=""
        break
    fi

    now=$(date +%s)

    # Fast-fail: kernel must show signs of life within 10s
    if ! $CK_KERNEL && [[ $now -ge $kernel_deadline ]]; then
        error "Kernel did not start within 10s ('Linux version' not seen)."
        dump_tail 30
        FAIL_REASON="kernel-no-start"
        break
    fi

    # Overall timeout
    if [[ $now -ge $boot_deadline ]]; then
        error "Boot timeout exceeded (${TIMEOUT}s) without reaching login prompt."
        dump_tail 40
        FAIL_REASON="timeout"
        break
    fi

    sleep 1
done

# --- Compute verdict ---------------------------------------------

VERDICT="FAIL"
EXIT_CODE=1
if $CK_LOGIN; then
    VERDICT="PASS"
    EXIT_CODE=0
fi

ck_str() { $1 && echo "PASS" || echo "FAIL"; }

echo ""
info "================ Summary ================"
info "  kernel started     : $(ck_str $CK_KERNEL)"
info "  initramfs ran      : $(ck_str $CK_INITRAMFS)"
info "  systemd PID 1      : $(ck_str $CK_SYSTEMD)"
info "  systemd target     : $(ck_str $CK_TARGET)"
info "  login: prompt      : $(ck_str $CK_LOGIN)"
info "  ----------------------------------------"
info "  Overall            : $VERDICT"
if [[ -n "${FAIL_REASON:-}" ]]; then
    info "  Failure reason     : $FAIL_REASON"
fi
info "  Serial log         : $LOG"
info "========================================="
echo ""

# --- Shutdown / keep ---------------------------------------------

graceful_shutdown() {
    local sock="$1"
    case "$SHUTDOWN_HELPER" in
        socat)
            printf 'system_powerdown\nquit\n' | socat - "UNIX-CONNECT:$sock" >/dev/null 2>&1 || return 1
            ;;
        nc)
            printf 'system_powerdown\nquit\n' | nc -U -q 1 "$sock" >/dev/null 2>&1 || \
                printf 'system_powerdown\nquit\n' | nc -U "$sock" >/dev/null 2>&1 || \
                return 1
            ;;
        *)
            return 1
            ;;
    esac
    return 0
}

wait_for_qemu_exit() {
    local secs="$1"
    for _ in $(seq 1 "$secs"); do
        kill -0 "$QEMU_PID" 2>/dev/null || return 0
        sleep 1
    done
    return 1
}

if $KEEP && [[ $EXIT_CODE -eq 0 ]]; then
    info "--keep: leaving VM running for inspection."
    info "  PID:           $QEMU_PID"
    info "  Monitor sock:  $MONITOR_SOCK"
    info "  Serial log:    $LOG"
    if [[ -n "$SHUTDOWN_HELPER" ]]; then
        info "  Shut down via: echo system_powerdown | $SHUTDOWN_HELPER ${SHUTDOWN_HELPER:+- }UNIX-CONNECT:$MONITOR_SOCK"
    fi
    info "Press Ctrl-C to terminate the VM and exit."

    # Trap SIGINT for clean shutdown
    trap 'info "SIGINT received — shutting down VM..."; \
          graceful_shutdown "$MONITOR_SOCK" || warn "graceful shutdown failed"; \
          wait_for_qemu_exit 30 || { warn "QEMU did not exit; killing"; kill -9 "$QEMU_PID" 2>/dev/null || true; }; \
          rm -rf "$TMPDIR_RUN"; \
          exit 0' INT

    # Wait for the QEMU process; if it exits on its own, we exit too.
    wait "$QEMU_PID" 2>/dev/null || true
    exit 0
fi

# Normal path: try graceful shutdown
if kill -0 "$QEMU_PID" 2>/dev/null; then
    if [[ -n "$SHUTDOWN_HELPER" ]]; then
        info "Sending system_powerdown via QEMU monitor ($SHUTDOWN_HELPER)..."
        if graceful_shutdown "$MONITOR_SOCK"; then
            if wait_for_qemu_exit 30; then
                info "QEMU shut down cleanly."
            else
                warn "QEMU did not exit within 30s — killing."
                kill "$QEMU_PID" 2>/dev/null || true
                sleep 2
                kill -9 "$QEMU_PID" 2>/dev/null || true
            fi
        else
            warn "Could not send powerdown via monitor — killing QEMU."
            kill "$QEMU_PID" 2>/dev/null || true
            sleep 2
            kill -9 "$QEMU_PID" 2>/dev/null || true
        fi
    else
        warn "Neither socat nor nc available — killing QEMU (not a graceful shutdown)."
        kill "$QEMU_PID" 2>/dev/null || true
        sleep 2
        kill -9 "$QEMU_PID" 2>/dev/null || true
    fi
fi

exit "$EXIT_CODE"
