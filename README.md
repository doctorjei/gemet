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

## Artifacts

Tenkei produces two families of outputs. The raw files under `build/` are
the primary artifact; the OCI / tarball / qcow2 forms are additive, for
consumers that want referenceable artifact URLs or self-contained disk
images.

| Form     | Output                                | Details                                 |
|----------|---------------------------------------|-----------------------------------------|
| Raw      | `build/vmlinuz`                       | compressed kernel (~7.5 MB)             |
| Raw      | `build/tenkei-initramfs.img`          | initramfs (~1.1 MB)                     |
| OCI      | `tenkei-kernel:<ver>`                 | kernel-as-OCI — see [docs/kernel-as-oci.md](docs/kernel-as-oci.md) |
| OCI      | `yggdrasil:<ver>`                     | minimal Debian 13 + systemd userland — see [docs/yggdrasil.md](docs/yggdrasil.md) |
| Tarball  | `build/yggdrasil-<ver>.tar.xz`        | Yggdrasil rootfs for `lxc-create`       |
| qcow2    | `build/yggdrasil-<ver>.qcow2`         | bootable disk image for `qemu -drive`   |

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
- The initramfs is a short shell script: mount virtiofs, switch_root, done
- The VM boots directly into the OCI image's own init -- it IS the machine
- Lifecycle management is handled by [kento](https://github.com/doctorjei/kento)

**What tenkei takes from Kata:**
- Kernel config fragments (virtio, virtiofs, networking, cgroups, etc.)
- Kernel patches for various versions
- The kernel build script (wrapped for standalone use)

**What tenkei replaces:**
- `kata-agent` -- replaced by a minimal shell init script
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

Optional OCI artifacts: `bash scripts/build-kernel-oci.sh` packages the
kernel + initramfs as `tenkei-kernel:<ver>` for downstream multi-stage
consumption, and `sudo bash rootfs/build-yggdrasil.sh` produces the
companion `yggdrasil:<ver>` minimal Debian userland. See
[docs/kernel-as-oci.md](docs/kernel-as-oci.md) and
[docs/yggdrasil.md](docs/yggdrasil.md).

### Boot Test

```bash
# 1. Create a test rootfs
sudo bash scripts/create-test-rootfs.sh /tmp/test-rootfs

# 2. Boot it
sudo bash scripts/test-boot.sh \
    --kernel build/vmlinuz \
    --initrd build/tenkei-initramfs.img \
    --rootfs /tmp/test-rootfs

# 3. SSH in (from another terminal)
ssh -p 2222 root@127.0.0.1
```

The test script handles virtiofsd, QEMU, networking, and cleanup automatically.
Run `bash scripts/test-boot.sh --help` for all options.

## Project Structure

```
tenkei/
+-- initramfs/
|   +-- init                 # Minimal virtiofs / block-dev mount + switch_root
|   +-- build.sh             # Packages initramfs (busybox + init)
+-- kernel/
|   +-- Containerfile        # kernel-as-OCI image source
+-- rootfs/
|   +-- build-yggdrasil.sh        # Yggdrasil OCI + .tar.xz builder
|   +-- build-yggdrasil-disk.sh   # Yggdrasil qcow2 builder
|   +-- seed-target.txt           # package keep-list
|   +-- networkd/                 # staged systemd-networkd config
|   +-- sshkey/                   # staged ssh-key sync service + script
+-- scripts/
|   +-- build-kernel.sh           # Kernel build wrapper (setup/build/install)
|   +-- build-kernel-oci.sh       # Package kernel + initramfs as OCI image
|   +-- test-boot.sh              # QEMU + virtiofsd boot test helper
|   +-- test-yggdrasil-lxc.sh     # Yggdrasil LXC smoke test
|   +-- test-yggdrasil-vm.sh      # Yggdrasil virtiofs VM smoke test
|   +-- test-yggdrasil-disk.sh    # Yggdrasil qcow2 boot smoke test
|   +-- create-test-rootfs.sh     # Creates minimal Debian rootfs for boot testing
|   +-- git-upstream.sh           # Manage upstream kata subtree imports
+-- docs/
|   +-- user-guide.md             # Usage documentation
|   +-- kernel-as-oci.md          # kernel-as-OCI artifact reference
|   +-- yggdrasil.md              # Yggdrasil artifact reference
|   +-- pve-integration-spec.md   # PVE config requirements for kento
+-- upstream/
|   +-- kernel/              # Kata kernel configs, patches, build script
|   +-- osbuilder/           # Kata rootfs/initrd/image builders
+-- VERSION                  # Version string
+-- LICENSE.md               # GPLv3
+-- build/                   # Output: vmlinuz + initramfs + yggdrasil artifacts (gitignored)
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
