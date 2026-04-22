#!/usr/bin/env bash
#
# ci-vm-boot-test — End-to-end VM boot regimen for tenkei rootfs variants.
#
# Runs on a KVM-capable host against staged build artifacts. Exercises
# the real kernel + initramfs + rootfs chain (no container layer), then
# reports per-tier pass/fail.
#
# Tiers (per variant):
#   A1  virtiofs + patched initramfs + diag-init       switch_root works (virtiofs)
#   A2  qcow2    + patched initramfs + diag-init       switch_root works (block-device)
#   B1  virtiofs + patched initramfs + default systemd reaches "login:" prompt
#   B2  qcow2    + patched initramfs + default systemd same, block-device path
#   C   systemd-probe unit dumps health markers to serial on boot:
#         - failed_units count
#         - systemd-resolved active
#         - /etc/resolv.conf stub-mode
#         - eth0 DHCP lease
#         - DNS lookup success
#   D   (bifrost only) SSH reachability — authorized_keys pre-injected,
#                      VM booted with hostfwd, `ssh -p <port> root@127.0.0.1 true`
#   R   regression control — virtiofs + *orig* (unpatched) initramfs +
#                            diag-init must NOT emit the marker (hang
#                            expected). Skipped if no orig initramfs is
#                            supplied.
#
# Usage:
#   ci-vm-boot-test.sh --build-dir=<dir> [--variant=yggdrasil|bifrost|all]
#                      [--orig-initramfs=<path>] [--skip-tier=<A|B|C|D|R>]...
#                      [--timeout=<sec>] [--keep-logs] [--ssh-port=<port>]
#
# Expected artifacts in <build-dir>:
#   vmlinuz                        the tenkei kernel
#   tenkei-initramfs.img           the patched initramfs
#   <variant>-<ver>.tar.xz         rootfs tarball
#   <variant>-<ver>.qcow2          rootfs disk image
#   VERSION                        optional; otherwise inferred from filenames
#
# Requirements:
#   qemu-system-x86_64, /usr/libexec/virtiofsd, tar, xz, sudo (NOPASSWD
#   for /dev/kvm), optionally virt-customize for Tier D.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Defaults ────────────────────────────────────────────────────────
BUILD_DIR=""
VARIANT="all"
ORIG_INITRAMFS=""
TIMEOUT_BOOT=60
TIMEOUT_SYSTEMD=120
SSH_PORT=2222
KEEP_LOGS=false
declare -A SKIP_TIER=()

info()  { printf '\033[1;34m>>>\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
error() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
pass()  { printf '  \033[1;32m[PASS]\033[0m %s\n' "$*"; }
fail()  { printf '  \033[1;31m[FAIL]\033[0m %s\n' "$*"; }
skip()  { printf '  \033[1;33m[SKIP]\033[0m %s\n' "$*"; }

usage() {
    sed -n '1,/^set /p' "$0" | sed -n '3,/^$/p' | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

# ── Arg parsing ─────────────────────────────────────────────────────
for arg in "$@"; do
    case "$arg" in
        --build-dir=*)      BUILD_DIR="${arg#*=}" ;;
        --variant=*)        VARIANT="${arg#*=}" ;;
        --orig-initramfs=*) ORIG_INITRAMFS="${arg#*=}" ;;
        --timeout=*)        TIMEOUT_BOOT="${arg#*=}"; TIMEOUT_SYSTEMD="${arg#*=}" ;;
        --skip-tier=*)      SKIP_TIER["${arg#*=}"]=1 ;;
        --keep-logs)        KEEP_LOGS=true ;;
        --ssh-port=*)       SSH_PORT="${arg#*=}" ;;
        -h|--help)          usage 0 ;;
        *)                  error "unknown arg: $arg  (try --help)" ;;
    esac
done

[[ -n "$BUILD_DIR" ]] || error "--build-dir is required"
[[ -d "$BUILD_DIR" ]] || error "build dir not found: $BUILD_DIR"
BUILD_DIR="$(cd "$BUILD_DIR" && pwd)"

# ── Resolve artifacts ──────────────────────────────────────────────
KERNEL="$BUILD_DIR/vmlinuz"
INITRAMFS="$BUILD_DIR/tenkei-initramfs.img"
[[ -f "$KERNEL" ]]    || error "missing $KERNEL"
[[ -f "$INITRAMFS" ]] || error "missing $INITRAMFS"

VERSION=""
if [[ -f "$BUILD_DIR/VERSION" ]]; then
    VERSION="$(tr -d '[:space:]' < "$BUILD_DIR/VERSION")"
fi

resolve_variant_files() {
    local var="$1" v="${VERSION:-}"
    if [[ -z "$v" ]]; then
        # Infer from the tar.xz filename
        local f
        f="$(ls "$BUILD_DIR"/"$var"-*.tar.xz 2>/dev/null | head -1)"
        [[ -n "$f" ]] || { echo ""; return 1; }
        v="$(basename "$f" .tar.xz | sed "s/^$var-//")"
    fi
    echo "$BUILD_DIR/$var-$v.tar.xz|$BUILD_DIR/$var-$v.qcow2|$v"
}

RESULTS_DIR="$BUILD_DIR/test-results"
mkdir -p "$RESULTS_DIR"

SUMMARY="$RESULTS_DIR/summary.txt"
: > "$SUMMARY"

# ── Tooling checks ─────────────────────────────────────────────────
for t in qemu-system-x86_64 tar xz sudo timeout; do
    command -v "$t" >/dev/null || error "missing $t"
done
VFSD=""
for p in /usr/libexec/virtiofsd /usr/bin/virtiofsd /usr/sbin/virtiofsd; do
    [[ -x "$p" ]] && { VFSD="$p"; break; }
done
[[ -n "$VFSD" ]] || error "virtiofsd not found"
[[ -e /dev/kvm ]] || error "/dev/kvm not present"
sudo -n true 2>/dev/null || error "sudo NOPASSWD required (for /dev/kvm access via qemu)"

# ── Helpers ────────────────────────────────────────────────────────
record() {
    local tier="$1" status="$2" msg="$3"
    printf '%-6s %-4s %s\n' "$tier" "$status" "$msg" >> "$SUMMARY"
    case "$status" in
        PASS) pass "$tier: $msg" ;;
        FAIL) fail "$tier: $msg" ;;
        SKIP) skip "$tier: $msg" ;;
    esac
}

tier_skipped() {
    local letter="$1"
    [[ -n "${SKIP_TIER[$letter]:-}" ]]
}

# Extract tar.xz into a directory (for virtiofs serving). Idempotent.
extract_rootfs() {
    local tarxz="$1" dest="$2"
    if [[ -d "$dest" && -f "$dest/.extracted-from" ]] && \
       [[ "$(cat "$dest/.extracted-from")" == "$tarxz" ]]; then
        return 0
    fi
    info "extracting $(basename "$tarxz") → $dest"
    rm -rf "$dest"
    mkdir -p "$dest"
    tar -xf "$tarxz" -C "$dest"
    echo "$tarxz" > "$dest/.extracted-from"
}

# Inject a diagnostic init script into the rootfs dir.
inject_diag_init() {
    local rootfs="$1"
    cat > "$rootfs/diag-init" <<'DIAG'
#!/bin/sh
echo "=== POST-SWITCH-ROOT-OK ===" > /dev/console 2>&1
echo "--- /proc mountpoint: $(mountpoint -q /proc && echo YES || echo NO) ---" > /dev/console
echo "--- /sys  mountpoint: $(mountpoint -q /sys  && echo YES || echo NO) ---" > /dev/console
echo "--- /dev  mountpoint: $(mountpoint -q /dev  && echo YES || echo NO) ---" > /dev/console
echo "=== DIAG COMPLETE; sleeping then exiting (kernel will panic) ===" > /dev/console
sleep 2
exit 0
DIAG
    chmod +x "$rootfs/diag-init"
}

# Inject a systemd probe unit that runs after multi-user and dumps
# health markers to serial, then powers off.
inject_systemd_probe() {
    local rootfs="$1"
    mkdir -p "$rootfs/usr/local/bin" "$rootfs/etc/systemd/system/multi-user.target.wants"
    cat > "$rootfs/usr/local/bin/tenkei-test-probe" <<'PROBE'
#!/bin/sh
exec > /dev/console 2>&1
echo ">>>TEST_PROBE_START<<<"
echo "failed_units: $(systemctl --failed --no-legend 2>/dev/null | wc -l)"
echo "resolved_active: $(systemctl is-active systemd-resolved 2>/dev/null)"
# resolv.conf stub (v1.4.1 contract)
if [ -L /etc/resolv.conf ]; then
    echo "resolv_conf_link: $(readlink /etc/resolv.conf)"
else
    echo "resolv_conf_link: (not a symlink)"
fi
rs=$(resolvectl status 2>/dev/null | awk -F': ' '/resolv.conf mode/{print $2; exit}')
echo "resolv_conf_mode: ${rs:-unknown}"
# DHCP lease on first network iface
lease=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $2 "=" $4; exit}')
echo "dhcp_lease: ${lease:-none}"
# DNS resolution via getent (hits systemd-resolved via nsswitch)
dns_ip=$(getent hosts deb.debian.org 2>/dev/null | awk '{print $1; exit}')
echo "dns_lookup: ${dns_ip:-none}"
echo ">>>TEST_PROBE_END<<<"
/sbin/poweroff
PROBE
    chmod +x "$rootfs/usr/local/bin/tenkei-test-probe"
    cat > "$rootfs/etc/systemd/system/tenkei-test-probe.service" <<'UNIT'
[Unit]
Description=Tenkei CI boot-test probe
After=multi-user.target network-online.target systemd-resolved.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/tenkei-test-probe
RemainAfterExit=no
StandardOutput=tty
StandardError=tty
TTYPath=/dev/console

[Install]
WantedBy=multi-user.target
UNIT
    ln -sf /etc/systemd/system/tenkei-test-probe.service \
        "$rootfs/etc/systemd/system/multi-user.target.wants/tenkei-test-probe.service"
}

# Start virtiofsd for a serving dir. Prints the socket path, backgrounds
# the daemon. Caller must stop_virtiofsd.
VFSD_PID=""
VFSD_SOCK=""
start_virtiofsd() {
    local serving="$1" label="$2"
    VFSD_SOCK="$RESULTS_DIR/vfsd-$label.sock"
    rm -f "$VFSD_SOCK"
    sudo "$VFSD" \
        --socket-path="$VFSD_SOCK" \
        --shared-dir="$serving" \
        --sandbox=none \
        --cache=auto \
        >"$RESULTS_DIR/vfsd-$label.log" 2>&1 &
    VFSD_PID=$!
    for _ in $(seq 1 25); do
        [[ -S "$VFSD_SOCK" ]] && break
        sleep 0.2
    done
    if [[ ! -S "$VFSD_SOCK" ]]; then
        warn "virtiofsd failed to start; log:"
        sed 's/^/    /' "$RESULTS_DIR/vfsd-$label.log" >&2
        return 1
    fi
    sudo chmod 666 "$VFSD_SOCK" 2>/dev/null || true
    return 0
}
stop_virtiofsd() {
    [[ -n "$VFSD_PID" ]] && sudo kill "$VFSD_PID" 2>/dev/null
    wait "$VFSD_PID" 2>/dev/null
    [[ -n "$VFSD_SOCK" ]] && rm -f "$VFSD_SOCK"
    VFSD_PID=""
    VFSD_SOCK=""
}

# ── Boot runners ──────────────────────────────────────────────────

# Common QEMU args piece.  Callers append -drive / -device / -kernel / etc.
# Defined as a proper array so multi-word options stay split.
QEMU_BASE=(
    -enable-kvm
    -cpu host
    -m 1024
    -smp 1
    -nographic
    -monitor none
    -no-reboot
)

# Boot with virtiofs root. Emits pass/fail via $? and leaves serial log at $LOG.
# Args: label, initramfs-path, append, serving-dir, timeout
# A user-mode NIC is attached so network-online.target can fire — the
# systemd probe unit depends on it.
boot_virtiofs() {
    local label="$1" initramfs="$2" append="$3" serving="$4" to="$5"
    local log="$RESULTS_DIR/$label.serial.log"
    : > "$log"
    start_virtiofsd "$serving" "$label" || return 2
    timeout "$to" sudo qemu-system-x86_64 \
        "${QEMU_BASE[@]}" \
        -kernel "$KERNEL" \
        -initrd "$initramfs" \
        -append "console=ttyS0 rootfstype=virtiofs root=rootfs $append" \
        -chardev "socket,id=vfs,path=$VFSD_SOCK" \
        -device "vhost-user-fs-pci,chardev=vfs,tag=rootfs" \
        -object "memory-backend-memfd,id=mem,size=1024M,share=on" \
        -numa "node,memdev=mem" \
        -netdev "user,id=net0" \
        -device "virtio-net-pci,netdev=net0" \
        -serial "file:$log" \
        </dev/null >"$RESULTS_DIR/$label.qemu.stdout" 2>&1
    local rc=$?
    stop_virtiofsd
    return $rc
}

# Boot with qcow2 block-device root. Args: label, initramfs, append, qcow2, to
boot_qcow2() {
    local label="$1" initramfs="$2" append="$3" qcow2="$4" to="$5"
    local log="$RESULTS_DIR/$label.serial.log"
    : > "$log"
    # Copy to a scratch file so we don't mutate the artifact
    local scratch="$RESULTS_DIR/$label.qcow2"
    cp --reflink=auto "$qcow2" "$scratch"
    timeout "$to" sudo qemu-system-x86_64 \
        "${QEMU_BASE[@]}" \
        -kernel "$KERNEL" \
        -initrd "$initramfs" \
        -append "console=ttyS0 root=/dev/vda rootfstype=ext4 $append" \
        -drive "file=$scratch,format=qcow2,if=virtio" \
        -netdev "user,id=net0" \
        -device "virtio-net-pci,netdev=net0" \
        -serial "file:$log" \
        </dev/null >"$RESULTS_DIR/$label.qemu.stdout" 2>&1
    local rc=$?
    return $rc
}

# Like boot_virtiofs but adds a hostfwd SSH forward for Tier D.
boot_virtiofs_ssh() {
    local label="$1" initramfs="$2" append="$3" serving="$4" to="$5" hostfwd="$6"
    local log="$RESULTS_DIR/$label.serial.log"
    : > "$log"
    start_virtiofsd "$serving" "$label" || return 2
    timeout "$to" sudo qemu-system-x86_64 \
        "${QEMU_BASE[@]}" \
        -kernel "$KERNEL" \
        -initrd "$initramfs" \
        -append "console=ttyS0 rootfstype=virtiofs root=rootfs $append" \
        -chardev "socket,id=vfs,path=$VFSD_SOCK" \
        -device "vhost-user-fs-pci,chardev=vfs,tag=rootfs" \
        -object "memory-backend-memfd,id=mem,size=1024M,share=on" \
        -numa "node,memdev=mem" \
        -netdev "user,id=net0,$hostfwd" \
        -device "virtio-net-pci,netdev=net0" \
        -serial "file:$log" \
        </dev/null >"$RESULTS_DIR/$label.qemu.stdout" 2>&1 &
    QEMU_PID=$!
    return 0  # background; caller tears down
}

# ── Tier implementations ───────────────────────────────────────────

tier_A1_virtiofs_diag() {
    local variant="$1" txz="$2"
    local label="${variant}-A1"
    local serving="$RESULTS_DIR/${variant}-rootfs-diag"
    extract_rootfs "$txz" "$serving"
    inject_diag_init "$serving"
    boot_virtiofs "$label" "$INITRAMFS" "init=/diag-init panic=5" \
        "$serving" "$TIMEOUT_BOOT"
    if grep -q "POST-SWITCH-ROOT-OK" "$RESULTS_DIR/$label.serial.log"; then
        record "A1" "PASS" "$variant: virtiofs + diag-init reached POST-SWITCH-ROOT-OK"
    else
        record "A1" "FAIL" "$variant: virtiofs diag-init marker absent"
    fi
}

tier_A2_qcow2_diag() {
    local variant="$1" qcow2="$2"
    local label="${variant}-A2"
    # qcow2 route: can't inject diag-init without mounting the image.
    # Use virt-customize if available; otherwise fall back to a pre-
    # extracted in-image path (/sbin/init symlinks to systemd — default
    # init will run). Here we just verify switch_root succeeds by
    # looking for tenkei's own pre-switch_root echo AND kernel boot
    # beyond it (presence of "Kernel panic" or "systemd" marker).
    if command -v virt-customize >/dev/null 2>&1; then
        local scratch="$RESULTS_DIR/${variant}-A2.qcow2"
        cp --reflink=auto "$qcow2" "$scratch"
        sudo virt-customize -a "$scratch" \
            --upload "$(declare_diag_init_file):/diag-init" \
            --run-command "chmod +x /diag-init" \
            >/dev/null 2>&1 || {
                record "A2" "FAIL" "$variant: virt-customize inject failed"
                return
            }
        boot_qcow2 "$label" "$INITRAMFS" "init=/diag-init panic=5" \
            "$scratch" "$TIMEOUT_BOOT"
        rm -f "$scratch"
        if grep -q "POST-SWITCH-ROOT-OK" "$RESULTS_DIR/$label.serial.log"; then
            record "A2" "PASS" "$variant: qcow2 + diag-init reached POST-SWITCH-ROOT-OK"
        else
            record "A2" "FAIL" "$variant: qcow2 diag-init marker absent"
        fi
    else
        # Skip — covered implicitly by Tier B2.
        record "A2" "SKIP" "$variant: virt-customize not installed (Tier B2 covers block path)"
    fi
}

# Helper for A2: write diag-init to a tempfile, echo path.
declare_diag_init_file() {
    local f="$RESULTS_DIR/.diag-init-payload"
    cat > "$f" <<'DIAG'
#!/bin/sh
echo "=== POST-SWITCH-ROOT-OK ===" > /dev/console 2>&1
sleep 2
exit 0
DIAG
    echo "$f"
}

tier_B1_virtiofs_systemd() {
    local variant="$1" txz="$2"
    local label="${variant}-B1"
    local serving="$RESULTS_DIR/${variant}-rootfs-systemd"
    extract_rootfs "$txz" "$serving"
    # Clear any stale diag-init to avoid Tier A cross-contamination
    rm -f "$serving/diag-init"
    inject_systemd_probe "$serving"
    boot_virtiofs "$label" "$INITRAMFS" "" "$serving" "$TIMEOUT_SYSTEMD"
    local ok=true reason=""
    if ! grep -qE "Reached target.*Multi-User|login:|>>>TEST_PROBE_START<<<" \
            "$RESULTS_DIR/$label.serial.log"; then
        ok=false; reason="no multi-user/login/probe marker"
    fi
    if $ok; then
        record "B1" "PASS" "$variant: virtiofs + systemd reached multi-user"
    else
        record "B1" "FAIL" "$variant: virtiofs systemd boot — $reason"
    fi
    # Run Tier C from the same boot log
    tier_C_parse_probe "$variant" "virtiofs" "$RESULTS_DIR/$label.serial.log"
}

tier_B2_qcow2_systemd() {
    local variant="$1" qcow2="$2"
    local label="${variant}-B2"
    # Inject probe via virt-customize if available; otherwise just boot
    # with default init and look for login prompt (no Tier C from qcow2).
    local qcow2_to_boot="$qcow2"
    local ran_probe=false
    if command -v virt-customize >/dev/null 2>&1; then
        local scratch="$RESULTS_DIR/${variant}-B2-probed.qcow2"
        cp --reflink=auto "$qcow2" "$scratch"
        sudo virt-customize -a "$scratch" \
            --mkdir /etc/systemd/system/multi-user.target.wants \
            --mkdir /usr/local/bin \
            --upload "$(declare_probe_files probe):/usr/local/bin/tenkei-test-probe" \
            --upload "$(declare_probe_files unit):/etc/systemd/system/tenkei-test-probe.service" \
            --run-command "chmod +x /usr/local/bin/tenkei-test-probe" \
            --run-command "ln -sf /etc/systemd/system/tenkei-test-probe.service /etc/systemd/system/multi-user.target.wants/tenkei-test-probe.service" \
            >/dev/null 2>&1 && { ran_probe=true; qcow2_to_boot="$scratch"; }
    fi
    boot_qcow2 "$label" "$INITRAMFS" "" "$qcow2_to_boot" "$TIMEOUT_SYSTEMD"
    [[ "$qcow2_to_boot" != "$qcow2" ]] && rm -f "$qcow2_to_boot"
    if grep -qE "Reached target.*Multi-User|login:|>>>TEST_PROBE_START<<<" \
            "$RESULTS_DIR/$label.serial.log"; then
        record "B2" "PASS" "$variant: qcow2 + systemd reached multi-user"
    else
        record "B2" "FAIL" "$variant: qcow2 systemd didn't reach multi-user"
    fi
    if $ran_probe; then
        tier_C_parse_probe "$variant" "qcow2" "$RESULTS_DIR/$label.serial.log"
    fi
}

# Helper: declare a probe payload file, echo its path.
declare_probe_files() {
    local which="$1"
    local f="$RESULTS_DIR/.probe-$which"
    case "$which" in
        probe)
            cat > "$f" <<'PROBE'
#!/bin/sh
exec > /dev/console 2>&1
echo ">>>TEST_PROBE_START<<<"
echo "failed_units: $(systemctl --failed --no-legend 2>/dev/null | wc -l)"
echo "resolved_active: $(systemctl is-active systemd-resolved 2>/dev/null)"
if [ -L /etc/resolv.conf ]; then
    echo "resolv_conf_link: $(readlink /etc/resolv.conf)"
else
    echo "resolv_conf_link: (not a symlink)"
fi
rs=$(resolvectl status 2>/dev/null | awk -F': ' '/resolv.conf mode/{print $2; exit}')
echo "resolv_conf_mode: ${rs:-unknown}"
lease=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $2 "=" $4; exit}')
echo "dhcp_lease: ${lease:-none}"
dns_ip=$(getent hosts deb.debian.org 2>/dev/null | awk '{print $1; exit}')
echo "dns_lookup: ${dns_ip:-none}"
echo ">>>TEST_PROBE_END<<<"
/sbin/poweroff
PROBE
            ;;
        unit)
            cat > "$f" <<'UNIT'
[Unit]
Description=Tenkei CI boot-test probe
After=multi-user.target network-online.target systemd-resolved.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/tenkei-test-probe
RemainAfterExit=no
StandardOutput=tty
StandardError=tty
TTYPath=/dev/console

[Install]
WantedBy=multi-user.target
UNIT
            ;;
    esac
    echo "$f"
}

tier_C_parse_probe() {
    local variant="$1" path_label="$2" logfile="$3"
    if ! grep -q ">>>TEST_PROBE_START<<<" "$logfile"; then
        record "C" "SKIP" "$variant($path_label): probe didn't run"
        return
    fi
    local section
    section="$(sed -n '/>>>TEST_PROBE_START<<</,/>>>TEST_PROBE_END<<</p' "$logfile")"
    local failed resolved resolv_link resolv_mode lease dns
    failed="$(    echo "$section" | awk -F': ' '/failed_units:/{print $2; exit}' | tr -d '[:space:]\r')"
    resolved="$(  echo "$section" | awk -F': ' '/resolved_active:/{print $2; exit}' | tr -d '[:space:]\r')"
    resolv_link="$(echo "$section" | awk -F': ' '/resolv_conf_link:/{print $2; exit}' | tr -d '\r')"
    resolv_mode="$(echo "$section" | awk -F': ' '/resolv_conf_mode:/{print $2; exit}' | tr -d '\r')"
    lease="$(     echo "$section" | awk -F': ' '/dhcp_lease:/{print $2; exit}' | tr -d '\r')"
    dns="$(       echo "$section" | awk -F': ' '/dns_lookup:/{print $2; exit}' | tr -d '\r')"
    [[ "$failed" == "0" ]] \
        && record "C1" "PASS" "$variant($path_label): no failed units" \
        || record "C1" "FAIL" "$variant($path_label): failed_units=$failed"
    [[ "$resolved" == "active" ]] \
        && record "C2" "PASS" "$variant($path_label): systemd-resolved active" \
        || record "C2" "FAIL" "$variant($path_label): systemd-resolved=$resolved"
    if [[ "$resolv_link" == *"stub-resolv.conf"* || "$resolv_mode" == *"stub"* ]]; then
        record "C3" "PASS" "$variant($path_label): resolv.conf in stub mode ($resolv_link / $resolv_mode)"
    else
        record "C3" "FAIL" "$variant($path_label): resolv.conf not stub (link=$resolv_link mode=$resolv_mode)"
    fi
    if [[ "$lease" == *"="*"."* ]]; then
        record "C4" "PASS" "$variant($path_label): DHCP lease $lease"
    else
        record "C4" "FAIL" "$variant($path_label): DHCP lease absent ($lease)"
    fi
    if [[ -n "$dns" && "$dns" != "none" ]]; then
        record "C5" "PASS" "$variant($path_label): DNS lookup → $dns"
    else
        record "C5" "FAIL" "$variant($path_label): DNS lookup failed"
    fi
}

tier_D_bifrost_ssh() {
    local variant="$1" txz="$2"
    [[ "$variant" == "bifrost" ]] || return 0
    local label="${variant}-D"
    local serving="$RESULTS_DIR/${variant}-rootfs-ssh"
    extract_rootfs "$txz" "$serving"
    rm -f "$serving/diag-init"
    # Inject a test authorized_keys so we can SSH in with a known key.
    # virtiofs passes UIDs through directly, so sshd inside the VM (root,
    # UID 0) must see a uid-0 authorized_keys with StrictModes-compatible
    # perms. Use sudo to set ownership; the harness is already running
    # sudo for qemu/virtiofsd.
    local testkey="$RESULTS_DIR/id_test"
    if [[ ! -f "$testkey" ]]; then
        ssh-keygen -t ed25519 -N '' -f "$testkey" -C "tenkei-ci-test" >/dev/null
    fi
    sudo mkdir -p "$serving/root/.ssh"
    sudo cp "$testkey.pub" "$serving/root/.ssh/authorized_keys"
    sudo chown -R 0:0 "$serving/root"
    sudo chmod 700 "$serving/root"
    sudo chmod 700 "$serving/root/.ssh"
    sudo chmod 600 "$serving/root/.ssh/authorized_keys"
    # The bifrost-hostkeys.service should generate host keys on first
    # boot; no pre-generation needed.
    QEMU_PID=""
    boot_virtiofs_ssh "$label" "$INITRAMFS" "" "$serving" "$TIMEOUT_SYSTEMD" \
        "hostfwd=tcp:127.0.0.1:$SSH_PORT-:22"
    if [[ -z "$QEMU_PID" ]]; then
        record "D" "FAIL" "$variant: QEMU failed to start"
        stop_virtiofsd
        return
    fi
    # Poll SSH for up to 90s
    local ok=false
    for i in $(seq 1 45); do
        if ssh -o StrictHostKeyChecking=no \
               -o UserKnownHostsFile=/dev/null \
               -o ConnectTimeout=3 \
               -i "$testkey" \
               -p "$SSH_PORT" \
               root@127.0.0.1 true 2>/dev/null; then
            ok=true; break
        fi
        sleep 2
    done
    sudo kill "$QEMU_PID" 2>/dev/null
    wait "$QEMU_PID" 2>/dev/null
    stop_virtiofsd
    if $ok; then
        record "D" "PASS" "$variant: SSH login via authorized_keys succeeded"
    else
        record "D" "FAIL" "$variant: SSH never became reachable"
    fi
}

tier_R_regression() {
    local variant="$1" txz="$2"
    [[ -n "$ORIG_INITRAMFS" ]] || { record "R" "SKIP" "$variant: no --orig-initramfs provided"; return; }
    [[ -f "$ORIG_INITRAMFS" ]] || { record "R" "FAIL" "$variant: orig initramfs missing: $ORIG_INITRAMFS"; return; }
    local label="${variant}-R"
    local serving="$RESULTS_DIR/${variant}-rootfs-diag"  # reuse from A1
    extract_rootfs "$txz" "$serving"
    inject_diag_init "$serving"
    boot_virtiofs "$label" "$ORIG_INITRAMFS" "init=/diag-init panic=5" \
        "$serving" "$TIMEOUT_BOOT"
    local logfile="$RESULTS_DIR/$label.serial.log"
    if grep -q "POST-SWITCH-ROOT-OK" "$logfile"; then
        record "R" "FAIL" "$variant: orig initramfs DID reach marker (regression control broken — bug not present?)"
    elif ! grep -q "tenkei:.*switching root" "$logfile"; then
        # No tenkei pre-switch_root echo means the supplied orig predates
        # that log line (pre-rootfstype-dispatch era) and can't be used as
        # a meaningful regression control. Skip cleanly; don't fail.
        record "R" "SKIP" "$variant: orig initramfs lacks tenkei marker (pre-dispatch era — supply a v1.4.1+ pristine initramfs to exercise R)"
    else
        record "R" "PASS" "$variant: orig initramfs hung after tenkei echo (regression confirmed)"
    fi
}

# ── Per-variant driver ────────────────────────────────────────────

run_variant() {
    local variant="$1"
    info "── Variant: $variant ─────────────────────────────────"
    local files tarxz qcow2 ver
    files="$(resolve_variant_files "$variant")" || { record "--" "SKIP" "$variant: artifacts not found"; return; }
    tarxz="${files%%|*}"; rest="${files#*|}"
    qcow2="${rest%%|*}";  ver="${rest#*|}"
    [[ -f "$tarxz" ]] || { record "--" "SKIP" "$variant: tar.xz missing: $tarxz"; return; }
    [[ -f "$qcow2" ]] || warn "$variant: qcow2 missing; Tier A2/B2 will skip"
    info "version $ver, tar.xz $(basename "$tarxz"), qcow2 $(basename "$qcow2")"

    tier_skipped A || tier_A1_virtiofs_diag "$variant" "$tarxz"
    if [[ -f "$qcow2" ]]; then
        tier_skipped A || tier_A2_qcow2_diag "$variant" "$qcow2"
    fi
    tier_skipped B || tier_B1_virtiofs_systemd "$variant" "$tarxz"
    if [[ -f "$qcow2" ]]; then
        tier_skipped B || tier_B2_qcow2_systemd "$variant" "$qcow2"
    fi
    tier_skipped D || tier_D_bifrost_ssh "$variant" "$tarxz"
    tier_skipped R || tier_R_regression "$variant" "$tarxz"
}

# ── Main ──────────────────────────────────────────────────────────
case "$VARIANT" in
    all)               VARIANTS=(yggdrasil bifrost) ;;
    yggdrasil|bifrost) VARIANTS=("$VARIANT") ;;
    *)                 error "invalid --variant: $VARIANT" ;;
esac

info "Results → $RESULTS_DIR"
info "Build dir: $BUILD_DIR"
info "Kernel:    $KERNEL"
info "Initramfs: $INITRAMFS"
[[ -n "$ORIG_INITRAMFS" ]] && info "Orig initramfs: $ORIG_INITRAMFS"

for v in "${VARIANTS[@]}"; do
    run_variant "$v"
done

info "────────────────────────────────────────────────────────"
info "Summary ($SUMMARY):"
cat "$SUMMARY"

pass_count=$(grep -c ' PASS ' "$SUMMARY" || true)
fail_count=$(grep -c ' FAIL ' "$SUMMARY" || true)
skip_count=$(grep -c ' SKIP ' "$SUMMARY" || true)
info "$pass_count passed, $fail_count failed, $skip_count skipped"

$KEEP_LOGS || {
    # Keep summary + serial logs; clean the intermediates
    find "$RESULTS_DIR" -maxdepth 1 \
        \( -name '*.qemu.stdout' -o -name '.probe-*' -o -name '.diag-init-payload' \
           -o -name 'vfsd-*.log' -o -name 'vfsd-*.sock' \) \
        -delete 2>/dev/null || true
}

[[ "$fail_count" -eq 0 ]] || exit 1
