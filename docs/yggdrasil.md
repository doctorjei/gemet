# Yggdrasil

Yggdrasil is tenkei's minimal Debian 13 + systemd foundation image. It serves
as the base layer for downstream rootfs builds (droste tiers, kento test
fixtures, user-defined images) and is published in three artifact forms: OCI
image, `.tgz` tarball, and qcow2 disk image.

## What it is

A stripped-down Debian 13 genericcloud rootfs with:

- systemd as PID 1 (udev, dbus kept; polkitd and resolved/timesyncd dropped)
- systemd-networkd configured for DHCP on all ethernet interfaces
- openssh-server with idempotent key-sync on boot via
  `/etc/yggdrasil/authorized_keys`
- busybox, nano, vim-tiny, curl, wget, tcpdump, traceroute, iptables for
  basic "poke around" ergonomics
- Locales for 15 common regions (~12 MB combined)

Kernel and bootloader packages are purged: Yggdrasil boots via an external
kernel + initramfs (tenkei's own) rather than a self-contained boot stack.

## Build

```bash
sudo bash rootfs/build-yggdrasil.sh
```

Produces OCI image `yggdrasil:<version>` (version from tenkei's `VERSION`
file). The `--no-import` flag builds the rootfs without importing into
podman/docker.

## SSH key sync contract

Orchestrators (kento, droste, humans) write authorized-keys lines to
`/etc/yggdrasil/authorized_keys` in the rootfs before starting the
container/VM. On each boot, `yggdrasil-sshkey-sync.service` runs
`/usr/local/sbin/sync-sshkeys.sh`, which appends any new lines to
`/root/.ssh/authorized_keys` (non-destructive — existing keys are
preserved).

- **Idempotent** — safe to run on every boot; duplicate lines are
  skipped via exact-line `grep -Fx` check.
- **Non-destructive** — keys are never removed or rewritten. Stale keys
  must be cleaned up manually; editing `/etc/yggdrasil/authorized_keys`
  and rebooting only adds, never subtracts.
- **No-op when absent** — the systemd unit has
  `ConditionPathExists=/etc/yggdrasil/authorized_keys`; if the file
  doesn't exist the service exits cleanly without touching anything.
- **Runs before ssh** — unit is ordered `Before=ssh.service sshd.service`
  so keys are in place before the SSH daemon starts accepting
  connections.

Comments (lines starting with `#`) and blank lines in the source file
are ignored.

## Plan and phases

Full design and phased implementation plan: `~/playbook/plans/yggdrasil.md`.

This file is a Phase 2/3 stub. Full documentation (artifact forms,
downstream consumption pattern) lands in Phase 7.
