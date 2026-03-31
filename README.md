# Tenkei

Minimal VM kernel and initramfs for booting OCI container images as virtual machines.

Tenkei provides the missing link between OCI images and lightweight VMs: a stripped-down
Linux kernel and initramfs that boots into a container rootfs served over virtiofs from
the host. No disk images, no image conversion -- the same Podman layer store that
[kento](https://github.com/doctorjei/kento) uses for LXC containers can also back
full virtual machines.

## How It Works

```
Host                              VM
+-----------------+    +---------------------+
| Podman layer    |    | tenkei kernel       |
| store           |    |   + initramfs       |
|   |             |    |     |               |
|   v             |    |     v               |
| virtiofsd -----------------> virtiofs mount |
| (shares rootfs) |    |     |               |
|                 |    |     v               |
|                 |    |   switch_root       |
|                 |    |     |               |
|                 |    |     v               |
|                 |    |   /sbin/init        |
+-----------------+    +---------------------+
```

1. **Host** runs `virtiofsd`, sharing the OCI rootfs (composed from Podman layers)
2. **QEMU/KVM** boots the tenkei kernel with the initramfs
3. **Initramfs** mounts the virtiofs share as the root filesystem
4. **`switch_root`** pivots into the container rootfs and execs `/sbin/init`

The VM boots in about 5 seconds with minimal memory overhead. The rootfs is shared
from the host -- no disk image to create, convert, or resize.

## Relationship to Kata Containers

Tenkei borrows kernel configs and build tooling from
[Kata Containers](https://github.com/kata-containers/kata-containers), but the
two projects solve different problems:

**What Kata does:**
- Full container runtime (`kata-runtime`) integrated with containerd/Kubernetes
- Runs a Go agent (`kata-agent`) inside the VM that receives gRPC commands
- The VM is a sandbox for OCI containers -- the host orchestrates everything

**What tenkei does:**
- No runtime, no agent, no containerd dependency
- The initramfs is 6 lines of shell: mount virtiofs, switch_root, done
- The VM boots directly into the OCI image's own init -- it IS the machine
- Lifecycle management is handled by [kento](https://github.com/doctorjei/kento)

**What tenkei takes from Kata:**
- Kernel config fragments (virtio, virtiofs, networking, cgroups, etc.)
- Kernel patches for various versions
- The kernel build script (wrapped for standalone use)

**What tenkei replaces:**
- `kata-agent` -- replaced by a ~6-line shell init script
- `kata-runtime` -- replaced by kento's VM management
- containerd shim -- not needed; kento talks to QEMU directly

The upstream Kata code lives in `upstream/` as git subtrees. Changes to these
files are not committed — they are overwritten on the next upstream sync.
Tenkei's own code wraps or overrides upstream behavior as needed. Local
customization (e.g., kernel config fragments) is fine for personal builds.

## Quick Start

### Build

```bash
# Build kernel + initramfs (output goes to build/)
bash scripts/build-kernel.sh 6.12.8
```

This downloads the kernel source, configures it with Kata's config fragments,
compiles it, builds the initramfs, and copies both to `build/`:

```
build/vmlinuz              -- compressed kernel (~7.5 MB)
build/tenkei-initramfs.img -- initramfs (~1.1 MB)
```

Build dependencies (Debian/Ubuntu):
```bash
apt install build-essential flex bison bc libelf-dev libssl-dev busybox-static
```

### Boot Test

```bash
# 1. Create a test rootfs
sudo debootstrap --variant=minbase bookworm /tmp/test-rootfs
sudo chroot /tmp/test-rootfs apt install -y udev systemd-sysv
sudo chroot /tmp/test-rootfs systemctl enable systemd-networkd \
    serial-getty@ttyS0.service
sudo chroot /tmp/test-rootfs bash -c 'echo root:test | chpasswd'

# 2. Enable DHCP (QEMU user-mode networking gives the guest 10.0.2.x)
sudo mkdir -p /tmp/test-rootfs/etc/systemd/network
cat <<'EOF' | sudo tee /tmp/test-rootfs/etc/systemd/network/80-dhcp.network
[Match]
Type=ether

[Network]
DHCP=yes
EOF
echo "nameserver 10.0.2.3" | sudo tee /tmp/test-rootfs/etc/resolv.conf

# 3. Boot it
sudo bash scripts/test-boot.sh \
    --kernel build/vmlinuz \
    --initrd build/tenkei-initramfs.img \
    --rootfs /tmp/test-rootfs

# 4. SSH in (from another terminal)
ssh -p 2222 root@127.0.0.1
```

The test script handles virtiofsd, QEMU, networking, and cleanup automatically.
Run `bash scripts/test-boot.sh --help` for all options.

## Project Structure

```
tenkei/
+-- initramfs/
|   +-- init                 # 6-line virtiofs mount + switch_root
|   +-- build.sh             # Packages initramfs (busybox + init)
+-- scripts/
|   +-- build-kernel.sh      # Kernel build wrapper (setup/build/install)
|   +-- test-boot.sh         # QEMU + virtiofsd boot test helper
|   +-- git-upstream.sh      # Manage upstream kata subtree imports
+-- upstream/
|   +-- kernel/              # Kata kernel configs, patches, build script
|   +-- osbuilder/           # Kata rootfs/initrd/image builders
+-- build/                   # Output: vmlinuz + initramfs (gitignored)
```

## Upstream Sync

Kata code is imported as git subtrees under `upstream/`. To pull latest:

```bash
bash scripts/git-upstream.sh pull
```

See `bash scripts/git-upstream.sh --help` for all commands.

## Related Projects

- [kento](https://github.com/doctorjei/kento) -- OCI images as LXC containers and VMs (manages tenkei VM lifecycle)
- [droste](https://github.com/doctorjei/droste) -- Nested-virtualization VM images for infrastructure testing
- [Kata Containers](https://github.com/kata-containers/kata-containers) -- Secure container runtime using lightweight VMs (upstream source for kernel configs)

## License

Tenkei's own code is licensed under the GNU General Public License v3.0.
See [LICENSE.md](LICENSE.md) for the full text.

Upstream code in `upstream/` is from Kata Containers, licensed under Apache 2.0.
