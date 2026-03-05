# Tenkei User Guide

## Overview

Tenkei builds a minimal Linux kernel and initramfs purpose-built for booting
OCI container images as virtual machines. It replaces traditional VM disk images
with a virtiofs-mounted rootfs served directly from the host's Podman layer store.

## Components

### Kernel

Tenkei uses the Kata Containers kernel configuration as a starting point — a
minimal kernel with just enough enabled for a guest VM:

- virtio drivers (PCI, net, console, block, SCSI)
- virtiofs (FUSE + virtio-fs)
- cgroups, namespaces, seccomp
- ext4/btrfs (for container workloads that expect them)
- No modules — everything built-in for single-image boot

The kernel configs live in `upstream/kernel/configs/fragments/`:
- `common/` — arch-independent fragments (virtio.conf, fs.conf, network.conf, etc.)
- `x86_64/` — x86_64-specific overrides

To build:

```bash
cd upstream/kernel
./build-kernel.sh setup    # download source + apply patches
./build-kernel.sh build    # compile
./build-kernel.sh install  # install to /usr/share/kata-containers/
```

Requirements: Go, yq v4.40.7, flex, bison, libelf-dev.

### Initramfs

Tenkei replaces Kata's agent-based initramfs with a minimal one that:

1. Mounts a virtiofs share as the root filesystem
2. Runs `switch_root` to pivot into it
3. Execs `/sbin/init` (systemd or whatever the container image provides)

The entire initramfs is essentially:

```sh
#!/bin/sh
mkdir -p /newroot
mount -t virtiofs rootfs /newroot
exec switch_root /newroot /sbin/init
```

Packaged with busybox for the mount/switch_root binaries, the initramfs is
under 5 MB.

### virtiofsd

The host-side component. `virtiofsd` shares a directory (the OCI rootfs) with
the guest VM over a Unix socket. QEMU connects the socket to a vhost-user-fs
device visible inside the guest.

```bash
# Share an OCI rootfs directory
virtiofsd \
    --socket-path=/tmp/vfs.sock \
    --shared-dir=/path/to/composed/rootfs
```

When used with kento, the rootfs is the same overlayfs composition of Podman
layers that kento uses for LXC containers.

## Usage

### Boot a VM from an OCI image

```bash
# 1. Compose the rootfs (using kento or manual overlayfs)
#    This produces a directory with the full container filesystem.

# 2. Start virtiofsd on the host
virtiofsd \
    --socket-path=/tmp/vfs.sock \
    --shared-dir=/path/to/rootfs &

# 3. Boot the VM
qemu-system-x86_64 \
    -kernel /path/to/vmlinuz \
    -initrd /path/to/initramfs.img \
    -m 512 -cpu host -enable-kvm \
    -chardev socket,id=vfs,path=/tmp/vfs.sock \
    -device vhost-user-fs-pci,chardev=vfs,tag=rootfs \
    -object memory-backend-memfd,id=mem,size=512M,share=on \
    -numa node,memdev=mem \
    -nographic \
    -append "console=ttyS0 rootfstype=virtiofs root=rootfs"
```

### Integration with kento

When kento gains VM support, the workflow simplifies to:

```bash
kento create-vm myvm --image docker.io/library/debian:bookworm
kento start myvm
```

Kento handles the virtiofsd lifecycle, rootfs composition, and QEMU invocation
internally.

## Kernel Configuration

### Fragment system

Rather than maintaining monolithic `.config` files, tenkei uses the upstream
Kata fragment system. Each feature area has its own config snippet:

| Fragment | Purpose |
|---|---|
| `base.conf` | Core kernel options |
| `virtio.conf` | virtio bus, PCI, balloon |
| `virtio-extras.conf` | virtiofs, vsock, SCSI |
| `fs.conf` | Filesystem support |
| `network.conf` | Basic networking |
| `netfilter.conf` | iptables/nftables (for container networking) |
| `security.conf` | Security modules |
| `seccomp.conf` | Seccomp BPF |
| `cgroup.conf` | Control groups |
| `serial.conf` | Serial console |
| `9p.conf` | 9p filesystem (fallback) |
| `debug.conf` | Debug options (optional) |

Fragments are merged by the build script into a final `.config`.

### Customizing

To add or remove kernel features:

1. Edit or add a fragment in `upstream/kernel/configs/fragments/common/`
2. For arch-specific options, use `upstream/kernel/configs/fragments/x86_64/`
3. Rebuild with `./build-kernel.sh setup && ./build-kernel.sh build`

## Troubleshooting

### VM doesn't boot
- Check that KVM is available: `ls /dev/kvm`
- Verify the kernel was built with virtiofs: `grep VIRTIO_FS .config`

### virtiofs mount fails inside VM
- Ensure `virtiofsd` is running on the host
- Check the socket path matches between virtiofsd and QEMU args
- Verify the kernel has CONFIG_VIRTIO_FS=y and CONFIG_FUSE_FS=y

### Slow boot
- Ensure `-enable-kvm` and `-cpu host` are passed to QEMU
- Check that the host CPU supports hardware virtualization

## Architecture Support

Currently targeting x86_64 only. ARM64 support is possible using the upstream
Kata arm64 kernel fragments but is not yet tested.
