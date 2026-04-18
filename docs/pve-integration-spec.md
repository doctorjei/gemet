# PVE Integration Spec: VM Mode (qemu-server)

This document specifies what kento needs to generate for
`/etc/pve/qemu-server/<vmid>.conf` when creating a tenkei-backed VM.
PVE config generation is a kento responsibility -- tenkei only provides
the kernel, initramfs, and the QEMU parameter requirements documented here.

Kento already generates `/etc/pve/lxc/<ctid>.conf` for containers.
The VM equivalent should follow the same pattern.

## Required QEMU Parameters

A tenkei VM needs these QEMU flags (from `scripts/test-boot.sh`):

```
-kernel <path-to-vmlinuz>
-initrd <path-to-initramfs>
-m <memory>
-enable-kvm -cpu host
-chardev socket,id=vfs,path=<virtiofsd-socket>
-device vhost-user-fs-pci,chardev=vfs,tag=rootfs
-object memory-backend-memfd,id=mem,size=<memory>M,share=on
-numa node,memdev=mem
-netdev user,id=net0,hostfwd=tcp:127.0.0.1:<port>-:22
-device virtio-net-pci,netdev=net0
-append "console=ttyS0 rootfstype=virtiofs root=rootfs"
```

The kernel and initramfs come from the OCI image's `/boot/vmlinuz` and
`/boot/initramfs.img`.

## Mapping to PVE qemu-server Config

PVE's `qemu-server` config format does not map 1:1 to raw QEMU flags.
PVE has its own abstraction layer with keys like `memory:`, `cpu:`,
`net0:`, etc. For anything PVE doesn't have a native config key for,
the `args:` key passes raw QEMU flags through verbatim.

**Important:** PVE has no native config key for direct kernel boot.
There is no `kernel:`, `initrd:`, or `cmdline:` key in qemu-server.
The kernel, initrd, and cmdline must all be passed through `args:` as
raw `-kernel`, `-initrd`, and `-append` QEMU flags.

Expected config structure:

```ini
# /etc/pve/qemu-server/<vmid>.conf

# --- Native PVE keys ---
memory: 512
cpu: host
kvm: 1
serial0: socket

# Networking (PVE manages bridge attachment, not SLIRP)
net0: virtio,bridge=vmbr0

# --- Raw QEMU flags (no native PVE equivalent) ---
# Direct kernel boot + virtiofs plumbing all go in args:
args: -kernel /path/to/vmlinuz -initrd /path/to/initramfs.img -append "console=ttyS0 rootfstype=virtiofs root=rootfs" -chardev socket,id=vfs,path=/run/kento/<vmid>/vfs.sock -device vhost-user-fs-pci,chardev=vfs,tag=rootfs -object memory-backend-memfd,id=mem,size=512M,share=on -numa node,memdev=mem
```

Notes on the mapping:

- `memory`, `cpu`, `kvm`, `net0`, `serial0` all have native PVE keys.
- Direct kernel boot (`-kernel`, `-initrd`, `-append`) has no native PVE
  key and must go in `args:`. PVE will silently ignore unknown top-level
  keys like `kernel:` or `cmdline:` — they parse fine but do nothing.
- The virtiofs plumbing (chardev, vhost-user-fs-pci, memory-backend-memfd,
  numa) also has no PVE equivalent and goes in `args:`.
- The `memory-backend-memfd` size in `args:` must match the `memory:` value.
- PVE networking uses bridge mode (not SLIRP user-mode). The bridge name
  depends on the host's network config (commonly `vmbr0`).
- Paths in `args:` with spaces or special characters need to be quoted.

## PVE-Specific Considerations

### vmid allocation

PVE uses integer IDs for both VMs and containers in a shared namespace.
Allocated IDs must not collide with existing VMs or CTs. Use `pvesh get
/cluster/nextid` or scan `/etc/pve/.vmlist` to find an available ID.

### pmxcfs

Configs written to `/etc/pve/` are stored in pmxcfs (the PVE cluster
filesystem). Changes are automatically synced across cluster nodes.
The config file must be valid PVE format or pmxcfs will reject it.

### virtiofsd lifecycle

PVE does not manage virtiofsd natively. Kento must:

1. Start virtiofsd before the VM boots, pointed at the composed rootfs.
2. Create the socket at a predictable path (e.g., `/run/kento/<vmid>/vfs.sock`).
3. Stop virtiofsd when the VM stops.
4. Clean up the socket on shutdown.

This is the same pattern kento already uses for standalone VM mode,
just with PVE managing the QEMU process instead of kento.

### Migration

Live migration requires:

- The virtiofsd socket path must be consistent across nodes.
- The rootfs backing store must be on shared storage (e.g., Ceph, NFS)
  accessible from all cluster nodes.
- virtiofsd must be started on the target node before migration completes.

This is non-trivial and can be deferred. Document it as unsupported initially.

### Existing pattern

Kento already generates `/etc/pve/lxc/<ctid>.conf` for containers.
The VM config generation should reuse the same infrastructure:
ID allocation, config writing, pmxcfs interaction, and lifecycle hooks.
