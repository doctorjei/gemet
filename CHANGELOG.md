# Changelog

All notable changes to Tenkei are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); Tenkei
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.5.0] — 2026-04-23

### Added
- `initramfs/init` catches `mount --move /dev|/proc|/sys` failures and
  post-`switch_root` exec failures with an actionable emergency-shell
  message (was: silent hang, same failure class as the v1.4.2
  `switch_root` fix).
- `scripts/ci-vm-boot-test.sh` Tier N failure-injection suite — asserts
  the emergency-shell marker against three boot-path regressions
  (wrong virtiofs tag, bad `rootfstype`, missing block device).

### Changed
- Error messages across build scripts, CI scripts, and `release.yml`
  reworked for actionability — 9 issues fixed cross-cutting (every
  failure names the broken input and suggests a next step).
- `.txz` rename is now script-side in `rootfs/build-*.sh` (was
  release-page rename only in v1.4.2); OCI release-page tarballs are
  now xz-compressed.

### Fixed
- Canopy no longer ships `/var/lib/systemd/deb-systemd-helper-enabled`
  state (43 entries / 14 `.dsh-also` files in v1.4.2 → 0 / 0 in v1.5.0).
  Caused `deb-systemd-helper` to skip re-enabling services when canopy
  was used as a build base that later reinstalled systemd units.

## [1.4.2] — 2026-04-22

### Added
- `scripts/ci-vm-boot-test.sh` — Tier 3 live-VM boot regimen.
- user-guide sections for Bifrost and Canopy.
- Documentation of the `.distrib` diversion pitfall for Canopy
  consumers rehydrating GNU tools.

### Fixed
- **`initramfs/init` switch_root hang.** Three root causes: (1) `/dev`,
  `/proc`, `/sys` were not moved into newroot before `switch_root`
  (systemd had no `/dev/console`); (2) file descriptors from initramfs
  kept the old root busy — now `switch_root -c /dev/console` reopens
  them; (3) the init path was hardcoded to `/sbin/init` — now parsed
  from `init=` on `/proc/cmdline` so kernels booted with custom inits
  work.

## [1.4.1] — 2026-04-20

### Added
- `systemd-resolved` restored in Yggdrasil (was inadvertently purged in
  1.4.0 Canopy-split refactor). Bifrost inherits.

### Changed
- `systemd-resolved.service` is explicitly stripped from Canopy (no
  init family → no DNS daemon).
- Tier 2 CI allowlists `systemd-resolved.service` as expected-active in
  Yggdrasil and Bifrost.

## [1.4.0] — 2026-04-20

### Added
- **Canopy** — third rootfs variant derived from Yggdrasil with the
  init family stripped (no pid1, udev daemon, or dbus daemon). Shared-
  library floor (`libsystemd0`, `libudev1`, `libpam0g*`) retained
  because apt/util-linux link it. ~46 MB `.tar.xz` / 71 MB qcow2 /
  182 packages. Tarball artifact: `canopy-<ver>.tar.xz`; OCI:
  `ghcr.io/doctorjei/tenkei/canopy:<ver>`.
- Release CI wired for bifrost and canopy alongside yggdrasil.

## [1.3.0] — 2026-04-20

### Added
- **Bifrost** — SSH-ready variant derived from Yggdrasil. Re-enables
  `ssh.service`, adds `bifrost-hostkeys.service` (oneshot
  `ssh-keygen -A`) and `bifrost-sshkey-sync`. Tarball:
  `bifrost-<ver>.tar.xz`; OCI:
  `ghcr.io/doctorjei/tenkei/bifrost:<ver>`.
- Kernel-compile fallback path kept alongside Kata prebuilt fetch so
  releases don't hard-fail when Kata's prebuilt artifact is missing.

### Removed
- SSH key-injection machinery removed from Yggdrasil base. Bifrost
  now owns the SSH opinion; downstream consumers requiring SSH should
  compose with `bifrost:<ver>` instead of `yggdrasil:<ver>`.

## [1.2.0] — 2026-04-20

### Added
- **Yggdrasil** — Debian 13 genericcloud-based rootfs variant. Multi-
  phase shrink (377 MB → 244 MB uncompressed). Tarball:
  `yggdrasil-<ver>.tar.xz`; qcow2 and OCI forms:
  `ghcr.io/doctorjei/tenkei/yggdrasil:<ver>`.
- **Kernel-as-OCI artifact** — `kernel/Containerfile`
  (`FROM scratch` + 2 COPYs) and
  `scripts/build-kernel-oci.sh`. Kernel is now distributable as
  `ghcr.io/doctorjei/tenkei/tenkei-kernel:<ver>`.
- **GitHub CI (Minimal tier)** — `.github/workflows/release.yml`: tag-
  triggered build, Tier 1 (structural) + Tier 2 (rootless podman +
  systemd) tests, GHCR push, Release creation. `workflow_dispatch`
  builds and tests without publishing.
- `scripts/ci-structural-tests.sh` — Tier 1 artifact inspection (no
  root required).
- `scripts/ci-systemd-test.sh` — Tier 2 systemd-in-OCI health check.
- `scripts/extract-oci.sh` — pure-shell OCI → dir/tar/qcow2 (no
  podman/root required).
- `scripts/yggdrasil-smoke-test.sh` — portable boot verification.
- Kata prebuilt-kernel fetch (replaces from-scratch compile in the
  default path); zstd-compressed Kata static tarballs supported (Kata
  3.28.0+); Kata kernel artifact cached by release tag.
- Kernel-cmdline dispatch in `initramfs/init` — selects virtiofs vs
  block device vs rootfs-on-initramfs at boot time.
- Yggdrasil SSH key-sync service (replaced in 1.3.0 by Bifrost).

### Changed
- Yggdrasil tarball artifact switched from gzip to xz (`.tar.xz`).
- Default kernel version bumped to 6.18.15.
- `sshd` disabled by default in Yggdrasil base (host keys are the
  composer's responsibility; Bifrost re-enables it).
- `initramfs/init` emits a success line before `switch_root` for
  easier boot-log triage.
- Docs restructured — per-artifact docs under `docs/` (yggdrasil,
  kernel-as-oci, pve-integration-spec, releases); user-guide
  reconciled with the actual qcow2 contract.

### Removed
- `scripts/build-yggdrasil-disk.sh` retired in favor of
  `scripts/extract-oci.sh` + qcow2 emission from the main builder.

### Fixed
- PVE integration spec: kernel/initrd/cmdline must go in `args:` (not
  top-level fields).
- Tier 2 `podman load` no-op detection — scripts now snapshot the
  image list before load so pre-existing images aren't `rmi`'d after
  test.

## [1.0.1] — 2026-04-02

### Added
- virtiofs DAX support in kernel config.
- `scripts/create-test-rootfs.sh` — minimal Debian rootfs for boot
  testing.
- `docs/pve-integration-spec.md` — Proxmox VE integration design.
- `VERSION` file (previously version lived only in git tags).

### Changed
- `scripts/test-boot.sh` aligned with kento's QEMU invocation for
  consistency across the two projects.

## [1.0.0] — 2026-03-31

Initial production release.

[1.5.0]: https://github.com/doctorjei/tenkei/releases/tag/v1.5.0
[1.4.2]: https://github.com/doctorjei/tenkei/releases/tag/v1.4.2
[1.4.1]: https://github.com/doctorjei/tenkei/releases/tag/v1.4.1
[1.4.0]: https://github.com/doctorjei/tenkei/releases/tag/v1.4.0
[1.3.0]: https://github.com/doctorjei/tenkei/releases/tag/v1.3.0
[1.2.0]: https://github.com/doctorjei/tenkei/releases/tag/v1.2.0
[1.0.1]: https://github.com/doctorjei/tenkei/releases/tag/v1.0.1
[1.0.0]: https://github.com/doctorjei/tenkei/releases/tag/v1.0.0
