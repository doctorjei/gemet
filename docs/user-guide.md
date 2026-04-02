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
# Setup + build + install in one step (output goes to build/)
bash scripts/build-kernel.sh 6.12.8

# Or separately
bash scripts/build-kernel.sh 6.12.8 setup    # download source + apply patches
bash scripts/build-kernel.sh 6.12.8 build    # compile
bash scripts/build-kernel.sh 6.12.8 install  # copy vmlinuz + initramfs to build/
```

Output:
- `build/vmlinuz` -- compressed kernel (~7.5 MB)
- `build/tenkei-initramfs.img` -- initramfs (~1.1 MB)

Requirements: build-essential, flex, bison, bc, libelf-dev, libssl-dev, busybox-static.

### Initramfs

Tenkei replaces Kata's agent-based initramfs with a minimal one that:

1. Mounts a virtiofs share as the root filesystem
2. Runs `switch_root` to pivot into it
3. Execs `/sbin/init` (systemd or whatever the container image provides)

The init script (`initramfs/init`):

```sh
#!/bin/sh
mount -t devtmpfs devtmpfs /dev
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mkdir -p /newroot
if ! mount -t virtiofs rootfs /newroot -o dax=inode; then
	echo "tenkei: virtiofs mount failed (tag=rootfs). Dropping to emergency shell."
	exec /bin/sh
fi
exec switch_root /newroot /sbin/init
```

To build:

```bash
bash initramfs/build.sh                              # default output
bash initramfs/build.sh /path/to/tenkei-initramfs.img  # custom output path
```

Requirements: busybox-static (`apt install busybox-static`).
Packaged with busybox, the initramfs is about 1.1 MB.

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

### Quick start

```bash
# 1. Build kernel + initramfs
bash scripts/build-kernel.sh 6.12.8

# 2. Create a test rootfs
sudo bash scripts/create-test-rootfs.sh /tmp/test-rootfs

# 3. Boot it (handles virtiofsd + QEMU + networking automatically)
sudo bash scripts/test-boot.sh \
    --kernel build/vmlinuz \
    --initrd build/tenkei-initramfs.img \
    --rootfs /tmp/test-rootfs

# 4. SSH in from another terminal
ssh -p 2222 root@127.0.0.1
```

Press Ctrl-A X to exit QEMU.

### Manual boot (without test-boot.sh)

```bash
# 1. Compose the rootfs (using kento or manual overlayfs)
#    This produces a directory with the full container filesystem.

# 2. Start virtiofsd on the host (sudo may be needed if the rootfs is root-owned)
virtiofsd \
    --socket-path=/tmp/vfs.sock \
    --shared-dir=/path/to/rootfs &

# 3. Boot the VM
qemu-system-x86_64 \
    -kernel build/vmlinuz \
    -initrd build/tenkei-initramfs.img \
    -m 512 -cpu host -enable-kvm \
    -chardev socket,id=vfs,path=/tmp/vfs.sock \
    -device vhost-user-fs-pci,chardev=vfs,tag=rootfs \
    -object memory-backend-memfd,id=mem,size=512M,share=on \
    -numa node,memdev=mem \
    -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22 \
    -device virtio-net-pci,netdev=net0 \
    -nographic \
    -append "console=ttyS0 rootfstype=virtiofs root=rootfs"
```

### Integration with kento

Kento provides full VM lifecycle management using tenkei's kernel and initramfs.
The OCI image must include `/boot/vmlinuz` and `/boot/initramfs.img` (typically
added by a [droste](https://github.com/doctorjei/droste) image layer, where droste
is the project's nested-virt VM image builder).

```bash
# Create a VM from an OCI image (--vm flag is required)
sudo kento container create docker.io/example/myimage --vm --name myvm --port 2222:22

# Start / stop / remove
sudo kento container start myvm
sudo kento container stop myvm
sudo kento container rm myvm

# List all containers (LXC and VM)
sudo kento container list
```

Kento handles everything automatically:
- Composes the OCI layers into an overlayfs rootfs
- Validates that `/boot/vmlinuz` and `/boot/initramfs.img` exist
- Starts virtiofsd to share the rootfs with the guest
- Launches QEMU/KVM with the correct virtiofs, networking, and console flags
- Tracks PIDs and cleans up on stop (virtiofsd, QEMU, mounts, sockets)

See the [kento VM mode docs](https://github.com/doctorjei/kento) for full details.

### Building VM-bootable OCI images

Kento expects the OCI image to contain tenkei's kernel and initramfs at
`/boot/vmlinuz` and `/boot/initramfs.img`. The
[droste](https://github.com/doctorjei/droste) project builds these images
using Containerfiles that copy tenkei's build output into the image and
configure the rootfs for VM boot.

A minimal VM-bootable Containerfile looks like:

```dockerfile
FROM debian:bookworm

# Install tenkei kernel + initramfs
COPY vmlinuz /boot/vmlinuz
COPY initramfs.img /boot/initramfs.img

# VM boot requirements
RUN > /etc/fstab \
    && echo 'root:password' | chpasswd \
    && apt-get update && apt-get install -y udev systemd-sysv \
    && mkdir -p /etc/systemd/network \
    && printf '[Match]\nType=ether\n\n[Network]\nDHCP=yes\n' \
       > /etc/systemd/network/80-dhcp.network \
    && systemctl enable systemd-networkd
```

Key requirements for a VM-bootable image:
- `/boot/vmlinuz` and `/boot/initramfs.img` present
- Empty `/etc/fstab` (stale entries from base images hang on boot)
- A user account with a password set (locked accounts can't login via console)
- systemd-networkd with a DHCP `.network` file for virtio NICs
- `udev` and `systemd-sysv` installed for full systemd boot

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
| `dax.conf` | DAX direct access for virtiofs |
| `9p.conf` | 9p filesystem (fallback) |
| `debug.conf` | Debug options (optional) |

Fragments are merged by the build script into a final `.config`.

### Customizing

To add or remove kernel features:

1. Edit or add a fragment in `upstream/kernel/configs/fragments/common/`
2. For arch-specific options, use `upstream/kernel/configs/fragments/x86_64/`
3. Rebuild with `bash scripts/build-kernel.sh <version>`

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

## DAX (Direct Access)

virtiofs supports DAX for memory-mapped file access, which bypasses the FUSE
request/response overhead. The tenkei kernel includes DAX support
(`CONFIG_FUSE_DAX=y`), and the initramfs mounts with `dax=inode` (per-inode
DAX, with graceful fallback when no DAX window is configured).

To enable DAX in test-boot.sh:

```bash
sudo bash scripts/test-boot.sh \
    --kernel build/vmlinuz \
    --initrd build/tenkei-initramfs.img \
    --rootfs /tmp/test-rootfs \
    --dax          # 256M default cache window
    # or: --dax 512M  for a larger window
```

This adds a `cache-size` parameter to the QEMU virtiofs device and switches
virtiofsd to `--cache=always`. The DAX cache window is allocated from the VM's
shared memory region.

For manual QEMU invocations, add `cache-size=256M` to the device line:

```
-device vhost-user-fs-pci,chardev=vfs,tag=rootfs,cache-size=256M
```

DAX is not enabled by default. It adds memory overhead (the cache window is
reserved) but reduces latency for filesystem I/O.

## Architecture Support

Currently targeting x86_64 only. ARM64 support is possible using the upstream
Kata arm64 kernel fragments but is not yet tested.
