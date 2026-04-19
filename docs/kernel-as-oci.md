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
FROM tenkei-kernel:1.1.0 AS tenkei-kernel

FROM debian:bookworm  # or yggdrasil:<ver>, etc.
COPY --from=tenkei-kernel /boot/vmlinuz /boot/vmlinuz
COPY --from=tenkei-kernel /boot/initramfs.img /boot/initramfs.img

# ... rest of the VM-bootable image setup (empty fstab, password,
# systemd-networkd DHCP, udev, systemd-sysv) ...
```

This replaces the older pattern of staging `vmlinuz` + `initramfs.img`
next to the Containerfile and using direct `COPY` statements.

## Version compatibility

`tenkei-kernel:<ver>` uses tenkei's own `VERSION` as its tag. The kernel
and initramfs inside are whatever was in `build/` at the time the image
was packaged, so tenkei's version reflects the project release, not the
Linux kernel version.

Downstream consumers that need a specific kernel version should pin on
tenkei's `VERSION` — this pins the kernel version that tenkei's build
scripts are wired up against for that release.

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
FROM tenkei-kernel:1.1.0 AS tenkei-kernel

FROM yggdrasil:1.1.0
COPY --from=tenkei-kernel /boot/vmlinuz /boot/vmlinuz
COPY --from=tenkei-kernel /boot/initramfs.img /boot/initramfs.img

# ... your customizations ...
```

---

*Last updated: 2026-04-19 (tenkei 1.1.0, Phase 7)*
