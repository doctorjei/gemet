# Tenkei

Minimal VM kernel and initramfs for booting OCI container images as virtual machines.

Tenkei provides the missing link between OCI images and lightweight VMs: a stripped-down
Linux kernel and initramfs that boots into a container rootfs served over virtiofs from
the host. No disk images, no image conversion — the same Podman layer store that
[kento](https://github.com/doctorjei/kento) uses for LXC containers can also back
full virtual machines.

## How It Works

```
Host                              VM
┌──────────────────┐    ┌─────────────────────┐
│ Podman layer     │    │ tenkei kernel       │
│ store            │    │   + initramfs       │
│   │              │    │     │               │
│   ▼              │    │     ▼               │
│ virtiofsd ──────────────► mount -t virtiofs │
│ (shares rootfs)  │    │     │               │
│                  │    │     ▼               │
│                  │    │   switch_root       │
│                  │    │     │               │
│                  │    │     ▼               │
│                  │    │   /sbin/init        │
└──────────────────┘    └─────────────────────┘
```

1. **Host** runs `virtiofsd`, sharing the OCI rootfs (composed from Podman layers)
2. **QEMU/KVM** boots the tenkei kernel with the initramfs
3. **Initramfs** mounts the virtiofs share as the root filesystem
4. **`switch_root`** pivots into the container rootfs and execs init

The VM boots in under a second with minimal memory overhead. The rootfs is shared
from the host — no disk image to create, convert, or resize.

## Project Structure

```
tenkei/
├── scripts/
│   └── git-upstream.sh       # Sync upstream kata-containers subtrees
├── upstream/
│   ├── kernel/               # Kata kernel build scripts + configs
│   └── osbuilder/            # Kata rootfs/initrd/image builders
├── initramfs/                # Tenkei's own minimal initramfs (TODO)
├── docs/
│   └── user-guide.md         # Usage documentation
└── playbook/
    └── devnotes.md           # Development notes and design decisions
```

## Quick Start

> **Status**: Early development. The upstream subtrees are imported; the custom
> initramfs and build pipeline are not yet implemented.

Prerequisites: QEMU with KVM, virtiofsd, Podman.

```bash
# Build the kernel (using upstream kata tooling)
cd upstream/kernel
./build-kernel.sh setup
./build-kernel.sh build

# Build the initramfs (TODO — tenkei's own minimal init)
# ...

# Boot a VM with an OCI rootfs
virtiofsd --socket-path=/tmp/vfs.sock --shared-dir=/path/to/rootfs &
qemu-system-x86_64 \
    -kernel vmlinuz \
    -initrd initramfs.img \
    -m 512 -cpu host -enable-kvm \
    -chardev socket,id=vfs,path=/tmp/vfs.sock \
    -device vhost-user-fs-pci,chardev=vfs,tag=rootfs \
    -object memory-backend-memfd,id=mem,size=512M,share=on \
    -numa node,memdev=mem \
    -append "rootfstype=virtiofs root=rootfs"
```

## Upstream Sync

Tenkei imports kernel configs and build tooling from the
[kata-containers](https://github.com/kata-containers/kata-containers) monorepo
as git subtrees. To pull the latest upstream changes:

```bash
bash scripts/git-upstream.sh pull
```

See `bash scripts/git-upstream.sh --help` for all commands.

## Related Projects

- [kento](https://github.com/doctorjei/kento) — OCI images as LXC system containers
- [droste](https://github.com/doctorjei/droste) — Nested-virtualization VM images for infrastructure testing
- [Kata Containers](https://github.com/kata-containers/kata-containers) — Secure container runtime using lightweight VMs

## License

TBD
