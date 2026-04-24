# Kernel as OCI

`tenkei-kernel:<version>` is a single-layer OCI image containing tenkei's
prebuilt kernel and initramfs. It is a companion artifact to the raw files
produced under `build/` — additive, not a replacement.

## What it is

A `FROM scratch` image with exactly two files:

```
/boot/vmlinuz
/boot/initramfs.img
```

Nothing else — no shell, no libc, no metadata beyond what `FROM scratch`
implies. The image is only useful as a source in a multi-stage build; you
cannot run it, exec into it, or use it as a rootfs.

Purpose: let downstream consumers pull tenkei's kernel and initramfs via
`COPY --from=tenkei-kernel:<ver>` rather than having tenkei's source tree
or build output staged on disk next to their Containerfile.

## Pulling from GHCR

As of tenkei 1.5.1, tagged releases are published to
`ghcr.io/doctorjei/gemet/boot:<ver>` (and `:latest`):

```bash
podman pull ghcr.io/doctorjei/gemet/boot:1.5.1
```

Versions 1.0.0 – 1.5.0 were published to
`ghcr.io/doctorjei/tenkei/tenkei-kernel:<ver>` and remain pullable at
their original tags. The local build target is still
`localhost/tenkei-kernel:<ver>` — the rename is GHCR-side only and
the full internal rename lands with the v2.0.0 Gemet migration.

See [releases.md](releases.md) for the full artifact inventory and the
draft-gate process for kernel/initramfs-touching releases.

## Build

First produce the raw build outputs, then package them:

```bash
bash scripts/build-kernel.sh <kver>       # populates build/vmlinuz + build/tenkei-initramfs.img
bash scripts/build-kernel-oci.sh          # uses ./VERSION (e.g. 1.1.0)
# or
bash scripts/build-kernel-oci.sh 1.1.0    # explicit version
```

Output: OCI image tagged `tenkei-kernel:<version>` and
`tenkei-kernel:latest`.

## Image contents

The Containerfile is deliberately trivial:

```dockerfile
FROM scratch

COPY vmlinuz /boot/vmlinuz
COPY initramfs.img /boot/initramfs.img
```

Two files, one layer, no runtime behavior.

## Downstream usage

The intended consumption pattern is a multi-stage Containerfile:

```dockerfile
FROM ghcr.io/doctorjei/gemet/boot:1.5.1 AS tenkei-kernel

FROM debian:bookworm  # or yggdrasil:<ver>, etc.
COPY --from=tenkei-kernel /boot/vmlinuz /boot/vmlinuz
COPY --from=tenkei-kernel /boot/initramfs.img /boot/initramfs.img

# ... rest of the VM-bootable image setup (empty fstab, password,
# systemd-networkd DHCP, udev, systemd-sysv) ...
```

This replaces the older pattern of staging `vmlinuz` + `initramfs.img`
next to the Containerfile and using direct `COPY` statements.

For consumers building locally against an unpublished version,
`localhost/tenkei-kernel:<ver>` works the same way as the GHCR tag.

## Version compatibility

`tenkei-kernel:<ver>` uses tenkei's own `VERSION` as its tag. The kernel
and initramfs inside are whatever was in `build/` at the time the image
was packaged, so tenkei's version reflects the project release, not the
Linux kernel version.

Downstream consumers that need a specific kernel version should pin on
tenkei's `VERSION` — this pins the kernel version that tenkei's build
scripts are wired up against for that release.

## Interchangeability with Kata kernels

Tenkei does not patch or specialize the kernel. `scripts/build-kernel.sh`
is a thin wrapper around upstream Kata's builder that uses Kata's stock
config fragments unmodified. The resulting `vmlinuz` is functionally
equivalent to any Kata Containers kernel built for the same version with
the same fragment set.

Practical consequence: if you have a Kata kernel binary on hand (from a
kata-containers release, an OCI image they publish, or a previous tenkei
build), you can drop it in at `build/vmlinuz` and skip the local kernel
compile entirely. The required configs — `CONFIG_VIRTIO_FS`,
`CONFIG_FUSE_DAX`, `CONFIG_VIRTIO_BLK`, `CONFIG_EXT4_FS`, plus the rest
of Kata's `common/` fragment — are already on by default in any Kata
build, so no per-fragment auditing is needed.

This also means tenkei's kernel is not a long-lived artifact in any
meaningful sense — bumping to a newer Kata kernel version is the same
operation as building one for the first time.

## Why OCI

The raw files (`build/vmlinuz` and `build/tenkei-initramfs.img`) still
exist and remain the primary artifact. The OCI form is additive — for
consumers that want a referenceable artifact URL rather than out-of-band
file copies. Nothing that uses the raw files has to change.

## Relationship to Yggdrasil

[Yggdrasil](yggdrasil.md) and kernel-as-OCI are independent artifacts
that compose naturally: Yggdrasil gives you a minimal Debian userland;
kernel-as-OCI gives you the boot stack. A "full VM image" Containerfile
typically pulls from both:

```dockerfile
FROM ghcr.io/doctorjei/gemet/boot:1.5.1 AS tenkei-kernel

FROM ghcr.io/doctorjei/gemet/yggdrasil:1.5.1
COPY --from=tenkei-kernel /boot/vmlinuz /boot/vmlinuz
COPY --from=tenkei-kernel /boot/initramfs.img /boot/initramfs.img

# ... your customizations ...
```

---

*Last updated: 2026-04-19 (tenkei 1.2.0 + release automation)*
