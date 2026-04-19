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
kernel + initramfs (tenkei's own — see [kernel-as-oci](kernel-as-oci.md))
rather than a self-contained boot stack.

## What's kept vs dropped

Relative to the Debian 13 genericcloud rootfs, Yggdrasil makes the
following targeted changes (see `rootfs/build-yggdrasil.sh` for the
authoritative package lists):

**Kept** (beyond the genericcloud default):

- `busybox` — kept for minimal-environment ergonomics
- `vim-tiny` — provides `/usr/bin/vi` after `vim`/`vim-common`/`vim-runtime`
  are dropped
- `nano` — explicit install (Debian default `$EDITOR`)
- `curl`, `wget`, `tcpdump`, `traceroute`, `iptables` — convenience tools
  that survive autoremove

**Dropped — kernel/boot** (via PURGE_PACKAGES):

- `linux-image-cloud-amd64`, `linux-sysctl-defaults`
- `grub-*`, `shim-*`, `mokutil`, `os-prober`, UEFI libs
- `netplan.io` + `netplan-generator` + `python3-netplan`
- `cloud-initramfs-growroot`, `dracut-install`, `pciutils`

**Dropped — Yggdrasil-specific**:

- `cloud-init`, `cloud-guest-utils`, `cloud-image-utils`, `cloud-utils`
- `polkitd`, `libpolkit-agent-1-0`, `libpolkit-gobject-1-0`
- `systemd-resolved` (DNS via libc + `/etc/resolv.conf`),
  `systemd-timesyncd`
- `unattended-upgrades`, `dmsetup`, `apparmor`
- `screen`, `qemu-utils`, `dosfstools`, `gdisk`, `genisoimage`
- `dhcpcd-base` (redundant with networkd)
- `reportbug`, `python3-reportbug`, `python3-debianbts`,
  `apt-listchanges`
- `ssh-import-id` (we have our own key injection)
- `bind9-host`, `bind9-libs` (`host`/`dig` not foundational; `ping` and
  name resolution still work via libc's `getaddrinfo`)
- `vim`, `vim-common`, `vim-runtime` (replaced by `vim-tiny`)

`apt autoremove --purge` runs after both strip phases; this reclaims
orphaned deps (e.g. much of the python3-* ecosystem pulled in by
cloud-init / reportbug / apt-listchanges).

Also cleaned up at the end: `/boot/*` and `/lib/modules/*` are removed,
and `/etc/fstab` is replaced with an empty placeholder (stale UUID mounts
from genericcloud hang boot in VM/container contexts).

## Build

```bash
sudo bash rootfs/build-yggdrasil.sh           # OCI + .tgz (default)
sudo bash rootfs/build-yggdrasil-disk.sh      # qcow2 (reads OCI or .tgz)
```

`build-yggdrasil.sh` produces OCI image `yggdrasil:<version>` (version from
tenkei's `VERSION` file) and `build/yggdrasil-<version>.tgz`. Flags to
selectively skip outputs: `--no-import` (no OCI image), `--no-tgz`
(no tarball). Both flags are independent.

`build-yggdrasil-disk.sh` produces `build/yggdrasil-<version>.qcow2` from
either the OCI image (default) or an existing `.tgz` (via `--from-tgz`).

## Artifact forms

Yggdrasil is published in three artifact forms, all produced from the
same rootfs work directory:

| Form        | Output                                    | Primary consumer                         |
|-------------|-------------------------------------------|------------------------------------------|
| OCI image   | `yggdrasil:<ver>` (in podman/docker)      | droste tiers, kento test fixtures        |
| `.tgz`      | `build/yggdrasil-<ver>.tgz`               | `lxc-create -t local --rootfs=<tgz>`     |
| qcow2       | `build/yggdrasil-<ver>.qcow2`             | External boot via `qemu -kernel -initrd` |

## Boot contracts

### virtiofs boot (OCI artifact, droste tiers)

Droste tiers layer on top of `yggdrasil:<ver>` and add tenkei's kernel +
initramfs via [kernel-as-oci](kernel-as-oci.md). The resulting image is
booted by kento over virtiofs, following tenkei's default contract:

```
root=rootfs rootfstype=virtiofs
```

This is the existing kento/tenkei boot path — no change from previous
tenkei releases.

### qcow2 boot contract (disk-image artifact)

The qcow2 is a **partition-less** single ext4 filesystem — no partition
table, no bootloader, no `/boot`. That means the guest sees the rootfs at
`/dev/vda`, not `/dev/vda1`. The kernel cmdline must include:

```
root=/dev/vda rootfstype=ext4
```

tenkei's initramfs dispatches on those cmdline args and mounts the block
device directly (see `initramfs/init`). The corresponding boot invocation
is:

```bash
qemu-system-x86_64 \
    -kernel build/vmlinuz \
    -initrd build/tenkei-initramfs.img \
    -drive file=build/yggdrasil-<ver>.qcow2,format=qcow2,if=virtio \
    -append "console=ttyS0 root=/dev/vda rootfstype=ext4"
```

`scripts/test-yggdrasil-disk.sh` wraps this with sensible defaults.

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

## Downstream consumption

Yggdrasil is designed to be the base for downstream Containerfile
layering. The canonical pattern combines Yggdrasil with tenkei's
[kernel-as-oci](kernel-as-oci.md) image to produce a self-contained
VM-bootable image in a single Containerfile:

```dockerfile
FROM tenkei-kernel:1.1.0 AS tenkei-kernel

FROM yggdrasil:1.1.0
COPY --from=tenkei-kernel /boot/vmlinuz /boot/vmlinuz
COPY --from=tenkei-kernel /boot/initramfs.img /boot/initramfs.img

# ... your customizations ...
```

Droste tiers will follow this pattern: each tier builds `FROM
yggdrasil:<ver>` (or from an earlier tier built on top of Yggdrasil) and
pulls the kernel/initramfs from `tenkei-kernel:<ver>` via
`COPY --from=`.

Downstream customizations are unrestricted — add packages, write config,
create users, disable services. Yggdrasil's only expectation is that the
ssh-key sync contract (`/etc/yggdrasil/authorized_keys`) remain intact
if you want orchestrator-injected keys to keep working.

## Testing

Minimum-viable boot tests for a freshly-built `yggdrasil:<ver>`:

```bash
sudo bash scripts/test-yggdrasil-lxc.sh
sudo bash scripts/test-yggdrasil-vm.sh
bash     scripts/test-yggdrasil-disk.sh
```

The LXC test boots Yggdrasil as a system container and runs a few probes
via `lxc-attach` (`systemctl is-system-running`, `/etc/os-release`,
`/etc/yggdrasil` existence). Pass `--keep` to leave the container in
place for post-mortem.

The VM test extracts the OCI rootfs to a temp dir, ensures
`serial-getty@ttyS0.service` is enabled (genericcloud historically skips
it), and hands off to `scripts/test-boot.sh` for the virtiofsd + QEMU
heavy lifting. Extra flags after `--` are forwarded (e.g. `-- --dax`,
`-- --no-kvm`).

The disk test boots the qcow2 artifact directly via QEMU with tenkei's
kernel + initramfs — no virtiofsd. Default SSH forward is `localhost:2223`
(different from the VM test's 2222 so both can run concurrently).

---

*Last updated: 2026-04-19 (tenkei 1.1.0, Phase 7)*
