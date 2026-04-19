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

## Plan and phases

Full design and phased implementation plan: `~/playbook/plans/yggdrasil.md`.

This file is a Phase 2 stub. Full documentation (artifact forms, SSH-key
contract, downstream consumption pattern) lands in Phase 7.
