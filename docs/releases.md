# Releases

Tenkei publishes releases automatically from tagged commits. Artifacts land
in two forms: **GitHub Release attachments** (raw files, for direct download
and manual consumption) and **OCI images on GHCR** (for `podman pull` and
multi-stage container builds).

Releases are cut from tags matching `v*` (e.g. `v1.2.0`) — pushing such a tag
triggers `.github/workflows/release.yml`, which builds every artifact form,
runs structural and systemd-in-OCI health checks, and publishes the release.

## Artifact inventory (per release)

### GitHub Release attachments

Attached to the release page at `github.com/doctorjei/tenkei/releases/tag/v<ver>`:

| File                               | Size    | Purpose                                                              |
|------------------------------------|--------:|----------------------------------------------------------------------|
| `vmlinuz`                          | ~7.5 MB | Compressed kernel. Drop at `build/vmlinuz` to skip local compile.    |
| `tenkei-initramfs.img`             | ~1.1 MB | gzip+cpio initramfs (busybox + virtiofs-aware init script).           |
| `yggdrasil-<ver>.tar.xz`           |  ~56 MB | Yggdrasil rootfs tarball for `lxc-create` or manual extraction.       |
| `yggdrasil-<ver>.qcow2`            |  ~87 MB | Bootable partition-less ext4 disk image for `qemu -drive`.             |
| `yggdrasil-<ver>-oci.tar`          |  ~84 MB | OCI archive of the Yggdrasil image (for air-gapped `podman load`).    |
| `tenkei-kernel-<ver>-oci.tar`      |  ~8.4 MB | OCI archive of the kernel-only image (multi-stage `COPY --from=`).    |

### OCI images on GHCR

Pushed to `ghcr.io/doctorjei/tenkei/` at both the exact version and `:latest`:

| Image                                                | What it contains                                               |
|------------------------------------------------------|----------------------------------------------------------------|
| `ghcr.io/doctorjei/tenkei/yggdrasil:<ver>`           | Full Yggdrasil rootfs. See [yggdrasil.md](yggdrasil.md).       |
| `ghcr.io/doctorjei/tenkei/yggdrasil:latest`          | Alias for the most recent tagged release.                      |
| `ghcr.io/doctorjei/tenkei/tenkei-kernel:<ver>`       | `/boot/vmlinuz` + `/boot/initramfs.img`. See [kernel-as-oci.md](kernel-as-oci.md). |
| `ghcr.io/doctorjei/tenkei/tenkei-kernel:latest`      | Alias for the most recent tagged release.                      |

Pulls work anonymously for public images:

```bash
podman pull ghcr.io/doctorjei/tenkei/yggdrasil:1.2.0
podman pull ghcr.io/doctorjei/tenkei/tenkei-kernel:1.2.0
```

Downstream multi-stage consumers (droste, kento test fixtures) should pull
`tenkei-kernel:<ver>` in a `FROM` stage and `COPY --from=` the two boot
files into their own rootfs image. See
[docs/kernel-as-oci.md](kernel-as-oci.md) for the canonical pattern.

## Release cadence and the draft gate

Every tag push runs the full pipeline. How the release is published
depends on what code changed since the previous tag:

- **Rootfs-only changes** (paths under `rootfs/`, `docs/`, or most of
  `scripts/`) publish immediately on green tests. No human gate.

- **Kernel or initramfs changes** (paths under `initramfs/`,
  `upstream/kernel/`, `kernel/`, `scripts/build-kernel*.sh`, or the
  workflow file itself) publish as **drafts** with a pre-publish
  checklist in the release body. The release is flagged `Draft` in the
  GitHub UI and its artifacts are only visible to maintainers.

A draft release is the CI's signal that the change surface includes
things the Tier 1+2 checks cannot fully validate (kernel boot,
initramfs `switch_root`, virtiofs handoff). A maintainer runs
`scripts/yggdrasil-smoke-test.sh` against the draft's artifacts on a
KVM-capable host, confirms all 5 serial-console checkpoints pass, then
flips the draft via the UI or:

```bash
gh release edit v<ver> --draft=false
```

Future work — see `~/playbook/tasks.md` "Gold tier" — will automate this
step via a self-hosted or KVM-enabled runner.

## How to trigger a release

```bash
git tag -a v1.2.0 -m "Release v1.2.0"
git push origin v1.2.0
```

The workflow does the rest. Expect ~25-30 min on a cold kernel cache,
a few minutes on a warm cache.

## Testing the pipeline without publishing

The release workflow also accepts `workflow_dispatch`. Running it via
the Actions UI (or `gh workflow run release.yml`) exercises every step
except GHCR push and release creation — a safe way to validate the
pipeline itself after workflow edits.

## Test tiers

Two automated tiers run on every release. The third is currently manual.

| Tier | What                                              | Runs where                | When                    |
|------|---------------------------------------------------|---------------------------|-------------------------|
| 1    | File inspection (kernel magic, initramfs cpio, tar.xz size, qcow2 validity, OCI rootfs structure, dpkg DB sanity) | `ubuntu-24.04` GH runner  | Every release + dispatch |
| 2    | systemd-in-OCI health (rootless podman boots yggdrasil's systemd, checks failed units, python3/bash exec, systemd-analyze verify) | `ubuntu-24.04` GH runner  | Every release + dispatch |
| 3    | Full VM boot (`yggdrasil-smoke-test.sh`: kernel + initramfs + virtiofs + login prompt) | KVM-capable host          | Manual (pre-publish for draft releases) |

Tier 1 is `scripts/ci-structural-tests.sh`. Tier 2 is
`scripts/ci-systemd-test.sh`. Both run locally with the same arguments
the workflow uses, so developers can reproduce any CI failure without
pushing.
