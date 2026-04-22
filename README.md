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
| OCI      | `yggdrasil:<ver>`                     | minimal Debian 13 + systemd userland (~210-230 MB) — see [docs/yggdrasil.md](docs/yggdrasil.md) |
| OCI      | `bifrost:<ver>`                       | Yggdrasil + opinionated SSH layer — see [docs/bifrost.md](docs/bifrost.md) |
| OCI      | `canopy:<ver>`                        | Yggdrasil minus init-family (no-init base) — see [docs/canopy.md](docs/canopy.md) |
| Tarball  | `build/yggdrasil-<ver>.txz`           | Yggdrasil rootfs for `lxc-create` (xz-compressed; same on the release page) |
| Tarball  | `build/bifrost-<ver>.txz`             | Bifrost rootfs (SSH-ready)              |
| Tarball  | `build/canopy-<ver>.txz`              | Canopy rootfs (no-init)                 |
| qcow2    | `build/yggdrasil-<ver>.qcow2`         | bootable disk image for `qemu -drive`   |
| qcow2    | `build/bifrost-<ver>.qcow2`           | bootable disk image (SSH-ready)         |
| qcow2    | `build/canopy-<ver>.qcow2`            | disk image (no-init; primarily for inspection) |

As of 1.2.0, the Yggdrasil build applies a multi-phase shrink (BusyBox
swap, targeted purges, doc/locale/man sweep, python library trim) that
reduces the rootfs from ~377 MB down to ~210-230 MB. Recovery scripts
(`yggdrasil-unshim`, `yggdrasil-rehydrate`) ship inside the image for
downstream tiers that need any dropped package or wiped doc tree back —
see [docs/yggdrasil.md](docs/yggdrasil.md) for details.

**Yggdrasil vs Bifrost vs Canopy:** Yggdrasil is the pure foundation —
full systemd + networkd, no SSH host keys, sshd disabled, no
authorized_keys machinery. Each downstream consumer (droste tiers,
kento fixtures) layers its own user and authorized-keys policy on top.
**Bifrost** is the derived SSH-ready companion for humans and ad-hoc
testing: Yggdrasil plus sshd enabled, host keys generated at first
boot, and an `/etc/bifrost/authorized_keys` staging path for pre-boot
key injection. **Canopy** is the inverse shape — Yggdrasil with the
init-family removed (no systemd pid1, no udev daemon, no dbus daemon),
intended as a base for no-init process containers where the caller
brings their own pid1 (tini, dumb-init) or runs as a bare process. See
[docs/bifrost.md](docs/bifrost.md) and [docs/canopy.md](docs/canopy.md)
for the full contracts.

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

**Kernel interchangeability:** tenkei does not patch or specialize the
kernel. `scripts/build-kernel.sh` is a thin wrapper around upstream Kata's
builder using Kata's stock config fragments unmodified, so a tenkei
`vmlinuz` is functionally equivalent to any Kata Containers kernel built
for the same version. If you have a Kata kernel binary on hand (release
artifact, OCI image, or prior build), you can drop it in at
`build/vmlinuz` and skip the local compile.

The upstream Kata code lives in `upstream/` as git subtrees. Changes to these
files are not committed — they are overwritten on the next upstream sync.
Tenkei's own code wraps or overrides upstream behavior as needed. Local
customization (e.g., kernel config fragments) is fine for personal builds.

## Quick Start

### Build

```bash
# Build kernel + initramfs (output goes to build/)
bash scripts/build-kernel.sh 6.18.15
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
|   +-- build-yggdrasil.sh        # Yggdrasil OCI + .txz + qcow2 builder
|   +-- build-bifrost.sh          # Bifrost derived-image builder (yggdrasil + SSH layer)
|   +-- build-canopy.sh           # Canopy derived-image builder (yggdrasil minus init-family)
|   +-- seed-target.txt           # package keep-list
|   +-- networkd/                 # staged systemd-networkd config
|   +-- bifrost/                  # Bifrost overlay: units + authorized_keys sync script
+-- scripts/
|   +-- build-kernel.sh           # Kernel build wrapper (setup/build/install)
|   +-- build-kernel-oci.sh       # Package kernel + initramfs as OCI image
|   +-- extract-oci.sh            # Pure-shell rootfs extractor (dir/tar/qcow2)
|   +-- test-boot.sh              # QEMU + virtiofsd boot test helper
|   +-- test-yggdrasil-lxc.sh     # Yggdrasil LXC smoke test
|   +-- test-yggdrasil-vm.sh      # Yggdrasil virtiofs VM smoke test
|   +-- test-yggdrasil-disk.sh    # Yggdrasil qcow2 boot smoke test
|   +-- yggdrasil-smoke-test.sh   # Portable VM boot smoke test (ships with releases)
|   +-- ci-structural-tests.sh    # CI Tier 1: file/structure checks on build/ artifacts
|   +-- ci-systemd-test.sh        # CI Tier 2: rootless podman + systemd-in-OCI health (yggdrasil)
|   +-- ci-bifrost-test.sh        # CI Tier 2: bifrost ssh.service contract
|   +-- ci-canopy-test.sh         # CI Tier 2: canopy no-pid1 structural runtime
|   +-- ci-vm-boot-test.sh        # CI Tier 3: full VM boot regimen (KVM-capable host)
|   +-- create-test-rootfs.sh     # Creates minimal Debian rootfs for boot testing
|   +-- git-upstream.sh           # Manage upstream kata subtree imports
+-- docs/
|   +-- user-guide.md             # Usage documentation
|   +-- releases.md               # Release artifact inventory + CI process
|   +-- kernel-as-oci.md          # kernel-as-OCI artifact reference
|   +-- yggdrasil.md              # Yggdrasil artifact reference
|   +-- bifrost.md                # Bifrost artifact reference (SSH-ready companion)
|   +-- canopy.md                 # Canopy artifact reference (no-init companion)
|   +-- pve-integration-spec.md   # PVE config requirements for kento
+-- .github/workflows/
|   +-- release.yml               # Tag-triggered build/test/publish pipeline
+-- upstream/
|   +-- kernel/              # Kata kernel configs, patches, build script
|   +-- osbuilder/           # Kata rootfs/initrd/image builders
+-- VERSION                  # Version string
+-- LICENSE.md               # GPLv3
+-- build/                   # Output: vmlinuz + initramfs + yggdrasil artifacts (gitignored)
```

## Releases

Tagged releases (`v*`) are built automatically by
`.github/workflows/release.yml`. Each release publishes:

- **GitHub Release attachments** at
  `github.com/doctorjei/tenkei/releases` — `vmlinuz`,
  `tenkei-initramfs.img`, `{yggdrasil,bifrost,canopy}-<ver>.{txz,qcow2}`
  (rootfs tarballs are xz-compressed with the canonical `.txz`
  extension; build scripts emit `.txz` locally too), and xz-compressed
  OCI archives (`-oci.txz`) for all four images.
- **OCI images on GHCR** —
  `ghcr.io/doctorjei/tenkei/{yggdrasil,bifrost,canopy,tenkei-kernel}:<ver>`
  (all also tagged `:latest`).

Consumers can `podman pull` the GHCR images or download the tarball/qcow2
forms directly from the release page. See
[docs/releases.md](docs/releases.md) for the full artifact inventory,
the draft-on-kernel-change gate, and how to trigger a manual pipeline
run via `workflow_dispatch`.

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
