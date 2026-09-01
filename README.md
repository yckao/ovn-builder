# Reproducible OVN and Open vSwitch Debian builds

This repository builds pinned OVN and Open vSwitch (OVS) sources into Debian
packages for Ubuntu 22.04 and Ubuntu 24.04. The same build graph can produce:

- a builder image containing the toolchain and both source trees;
- a byte-verifiable directory of generated `.deb` files;
- a conventional Docker carrier image with those files under `/workdir`;
- an Ubuntu-based OVS or OVN runtime image; and
- an optional ORAS/OCI package artifact.

The conventional carrier is the primary air-gap transport. It is a normal
Docker image, so an environment that permits Docker images but not arbitrary
OCI artifacts can load it and copy the packages out. See
[the air-gap guide](docs/airgap.md) for the complete transfer procedure.

## Version 1 scope

The initial release lock selects:

| Component | Version | Locked source |
| --- | --- | --- |
| OVN | 26.03.2 | commit `3facc3b5e99ba2c863ec5f47f37466397f735802` |
| OVS | 3.7.1 | commit `7921d9c6924b8934ea1de9481891ac1172649280` |
| Architecture | amd64 | `linux/amd64` |
| DPDK | disabled | `DEB_BUILD_OPTIONS=nodpdk` for OVS |
| LTO | disabled | avoids runner-specific linker jobserver behavior |
| Debug-symbol packages | disabled | v1 ships installable runtime/development packages only |

All authoritative source, image, snapshot, and kernel selections are in
[`release-lock.json`](release-lock.json). Docker Bake defaults mirror that
lock. Change the lock, Bake variables, validation assertions, and CI matrix as
one reviewed release change; overriding only one version at the command line
does not create a complete release definition.

The CI execution toolchain is independently pinned in
[`.github/toolchain-lock.json`](.github/toolchain-lock.json): Buildx has an
exact release, the `docker-container` driver uses a digest-pinned BuildKit
image, and release jobs install an exact ORAS CLI version.

Version 1 carriers have the `generated-only` profile. They contain the OVN/OVS
packages produced by this build, but they are **not** complete offline APT
repositories and do not contain every Ubuntu dependency. A target needs an
approved, compatible Ubuntu package source or an independently prepared
dependency closure. The limitation and the planned full-offline profile are
described in [docs/airgap.md](docs/airgap.md#generated-only-means-generated-only).

The r1 DEBs retain upstream package versions in both Ubuntu lanes. Because
same-version Jammy and Noble rebuilds are not interchangeable, their carriers
and repositories must remain strictly separated and approved by bundle/DEB
hash, not by dpkg version alone. The air-gap guide documents the reinstall
constraint; a distro-specific Debian revision suffix is reserved for a later
packaging revision.

## Build architecture

```text
release-lock + digest-pinned inputs
                 |
                 v
        target Ubuntu builder
        sources + build tools
                 |
          +------+------+
          |             |
       OVS DEBs      OVN DEBs
          |             |
          +------v------+
          canonical bundle
          DEBs + manifest + hashes
                 |
       +---------+----------+
       |         |          |
 local export  carrier    runtime image
               image
```

The multi-stage [`Dockerfile`](Dockerfile) uses:

- a Dockerfile frontend pinned by digest;
- Ubuntu bases pinned by digest;
- an OVS release archive pinned by SHA-256;
- an OVN Git checkout pinned to a commit;
- timestamped Ubuntu snapshot repositories; and
- `SOURCE_DATE_EPOCH`, sorted inputs, normalized file modes, and normalized
  bundle timestamps.

Build parallelism is locked to four jobs. Automatic `-dbgsym` packages are
disabled in v1; this avoids presenting a silently incomplete debug package set
as part of the carrier contract.

The `builder-u2204` and `builder-u2404` targets contain the complete build
environment. The source trees are `/usr/src/openvswitch` and `/usr/src/ovn`,
and the interactive working directory is `/workspace`.

The carrier stages copy the canonical bundle to `/workdir`, run as
`65534:65534`, declare no volume, and default to strict SHA-256 verification.
The runtime stages install the selected generated packages and resolve their
remaining dependencies from the locked Ubuntu snapshot during image build.
Their default command prints the OVS or OVN version; they are base/runtime
images, not a systemd or multi-daemon supervisor.

## Supported matrix

The curated matrix is kept in [`.github/ci-matrix.json`](.github/ci-matrix.json).
It is deliberately four explicit rows rather than an unrestricted Cartesian
product.

| Cell | Bundle contents | DEB target | Image group | Kernel compatibility test |
| --- | --- | --- | --- | --- |
| `ovs-u2204` | OVS 3.7.1 | `debs-ovs-u2204` | `images-ovs-u2204` | Ubuntu 22.04, `6.8.0-52-generic` |
| `ovs-u2404` | OVS 3.7.1 | `debs-ovs-u2404` | `images-ovs-u2404` | Ubuntu 24.04 GA, locked as `6.8.0-138-generic` |
| `ovn-u2204` | OVN 26.03.2 and OVS 3.7.1 | `debs-ovn-u2204` | `images-ovn-u2204` | Ubuntu 22.04, `6.8.0-52-generic` |
| `ovn-u2404` | OVN 26.03.2 and OVS 3.7.1 | `debs-ovn-u2404` | `images-ovn-u2404` | Ubuntu 24.04 GA, locked as `6.8.0-138-generic` |

An OVN bundle intentionally includes the matching OVS packages. An OVS bundle
contains only OVS build output. Version 1 publishes amd64 images only; adding
another architecture requires a new lock and CI rows rather than changing
`PLATFORM` alone.

## Quick start

Use a Linux host or runner with Docker Engine and Docker Buildx. `make validate`
also needs `jq`. Host-side full bundle verification needs Bash, GNU coreutils,
GNU findutils, `jq`, and `dpkg-deb`.

Validate the release definition and build plan:

```console
$ make validate
```

Export one package bundle into `dist/`:

```console
$ make debs TARGET=debs-ovn-u2204
$ ./scripts/bundle/verify.sh dist/ovn/u2204
```

The other export targets are `debs-ovs-u2204`, `debs-ovs-u2404`, and
`debs-ovn-u2404`. `make all` builds all four local bundle exports.

Build and load a conventional carrier plus its runtime image:

```console
$ make images TARGET=images-ovn-u2204
$ docker image ls 'local/ovn-builder/*'
```

For the default local prefix, that command creates:

```text
local/ovn-builder/ovn-debs:26.03.2-ovs3.7.1-r1-ubuntu22.04-amd64
local/ovn-builder/ovn:26.03.2-ovs3.7.1-r1-ubuntu22.04-amd64
```

Build and load the source-and-toolchain image:

```console
$ make builder TARGET=builder-u2204
$ docker run --rm -it \
    local/ovn-builder/builder:ovn26.03.2-ovs3.7.1-r1-ubuntu22.04-amd64
```

Set a repository prefix when needed:

```console
$ IMAGE_PREFIX=registry.example/infra/ovn-builder \
    make images TARGET=images-ovn-u2404
```

## Bundle contract

An exported bundle and `/workdir` in a carrier have the same layout:

```text
*.deb
SHA256SUMS
manifest.v1.json
metadata/
  source-lock.json
  ovs/
  ovn/                 # OVN bundles only
```

`manifest.v1.json` identifies the schema and profile, source commits, target
Ubuntu release and architecture, expected kernel, base image, APT snapshot,
release-lock digest, and the size, checksum, identity, version, architecture,
and dependency fields of each DEB. `SHA256SUMS` covers every payload and
metadata file except itself.

The source lock also records the checksum of a small downstream Debian patch.
It normalizes the Automake distribution tar embedded by `openvswitch-source`;
without it, files generated by `dh_autoreconf` give that otherwise architecture-
independent package wall-clock mtimes.

The full verifier rejects missing or extra files, unsafe checksum paths,
duplicate entries, symlinks and special files, incorrect modes, checksum
mismatches, manifest ordering errors, and DEB metadata that disagrees with
`dpkg-deb`.

## Reproducibility boundary

The manual `Reproducibility` workflow performs two no-cache builds for every
matrix cell and compares the verified exported bundle trees byte for byte.
This is the current v1 reproducibility gate.

Only deterministic metadata is placed in that bundle. `dpkg-buildpackage`
also creates per-run `.buildinfo` and `.changes` files; its `.buildinfo`
contains a wall-clock `Build-Date`, and `.changes` hashes that file. They are
therefore deliberately excluded from the reproducible carrier instead of
being rewritten after generation. The source lock, installed build-package
inventory, build flags, package manifest, and DEB hashes remain in `/workdir`.
Unmodified raw files can be exported separately, for example with
`make provenance TARGET=provenance-ovn-u2204`; their hashes are intentionally
not referenced by the reproducible bundle.

Upstream OVS's `make debian-deb` path invokes `debian/rules binary` directly
and does not emit `.buildinfo` or `.changes`, so the `provenance-ovs-*` export
is empty in r1. OVS build flags and its complete installed-package inventory
remain in deterministic bundle metadata; standardized raw OVS upload-control
provenance is an r2 packaging improvement.

The following are separate integrity records rather than part of that byte
comparison:

- a registry image digest identifies the published image;
- `SHA256SUMS` identifies files inside the bundle; and
- a SHA-256 of the exact `docker save` archive protects an air-gap transfer.

A Docker archive is a transport serialization and is not the reproducibility
boundary: independently saving the same image need not produce byte-identical
tar files. Do not treat a mutable tag such as `latest` as an integrity
identifier.

## Kernel testing semantics

Container builds do not boot the target kernel. A container shares the build
host's kernel, so a successful image build or container smoke test cannot prove
kernel-module compatibility. Bundle metadata therefore calls the selected ABI
the `expected_kernel`, and images use the `io.ovn-builder.target-kernel` label;
neither field is a claim that the ABI was boot-tested.

The normal CI matrix verifies packages, carrier behavior, extraction, and
runtime version commands on GitHub-hosted runners. Exact kernel validation is a
separate, manually enabled job on pre-provisioned self-hosted machines. It:

1. asserts that `uname -r` exactly matches the matrix value;
2. loads the matching host distribution's `openvswitch` kernel module and
   checks its path and vermagic;
3. downloads both the standalone OVS and combined OVN artifacts for that
   Ubuntu release and proves their OVS DEBs are byte-for-byte identical;
4. installs OVS DEBs only from the standalone artifact and OVN DEBs only from
   the combined artifact, then verifies the installed versions;
5. creates and inspects a test bridge; and
6. starts `ovn-central.service` and `ovn-host.service`, verifies the NB and SB
   databases plus `ovn-northd` and `ovn-controller`, binds a logical port to a
   CI chassis through an internal interface, and checks controller flows on
   `br-int`.

Ubuntu 22.04 is fixed to `6.8.0-52-generic` as requested. Ubuntu 24.04 follows
the server GA `linux-generic` policy, but a reproducible release still records
the exact resolved ABI; v1 records `6.8.0-138-generic`. Moving that default is
an explicit lock and runner-image update.

## Version rationale

OVN 26.03.2 records an upstream OVS gitlink corresponding to OVS 3.7.0. The v1
release preserves that fact in its manifest but builds against and ships OVS
3.7.1. Upstream OVS announced a security issue affecting 3.7.0 and fixed it in
3.7.1, and the OVS 4.0 announcement designates the 3.7 series as the new LTS.
For that reason, 3.7.1 is the conservative default rather than shipping the
exact vulnerable 3.7.0 gitlink.

OVS 4.0 is a separate current-line compatibility target, not an in-place
replacement hidden behind the same tag. Before adding it, add explicit matrix
rows and run package, OVN feature-probe, upgrade, runtime, and exact-kernel
tests. Keep the 3.7.1 and 4.0 package sets in separate carriers and offline
repositories so APT cannot silently select the higher version.

Primary upstream references:

- [OVN 26.03.2 source tag](https://github.com/ovn-org/ovn/tree/v26.03.2)
- [OVN build guidance](https://docs.ovn.org/en/stable/intro/install/general.html)
- [OVN runtime upgrade compatibility](https://docs.ovn.org/en/latest/intro/install/ovn-upgrades.html)
- [OVS security advisory for CVE-2026-34956](https://mail.openvswitch.org/pipermail/ovs-announce/2026-March/000393.html)
- [OVS 4.0 release and 3.7 LTS announcement](https://mail.openvswitch.org/pipermail/ovs-announce/2026-August/000400.html)

## GitHub Actions

Repository-side configuration, protected environments, GHCR permissions, and
the initial publication sequence are documented in
[`docs/github-setup.md`](docs/github-setup.md).

`Build and test` derives its jobs from `.github/ci-matrix.json`. Its four
product jobs build and smoke-test the bundle, conventional carrier archive, and
runtime archive. Its two builder jobs build and smoke-test conventional Docker
archives containing the complete source and toolchain environment. The ten
Docker archives are grouped into six 14-day GitHub artifacts. BuildKit's
auxiliary build-record upload is disabled so the release input set is closed
and predictable.

Exact-kernel jobs run only for a manual dispatch from `main` with
`kernel_tests=true` and matching protected, ephemeral self-hosted runners. Each
runner downloads its standalone OVS and combined OVN artifact from the same CI
run, compares every OVS DEB byte for byte, and then installs the OVS userspace
from the standalone artifact alongside only the OVN packages from the combined
artifact. The script temporarily inhibits package-service autostart, uses
bounded readiness probes, and removes its logical topology, chassis, external
IDs, interfaces, and services before the single-use runner is discarded.
The runner must not use OVS for its own networking: OVS, `ovn-central`, and
`ovn-host` must all be inactive when the job begins, and the script fails before
mutation if it finds an existing OVN integration bridge or OVN external IDs.

`Reproducibility` is also manually dispatched. It performs two no-cache bundle
builds per product cell, uploads all eight bundles, and runs four byte-for-byte
comparison jobs.

When exact-kernel runners are unavailable, dispatch `Publish build-only` from
the same `main` commit and supply a manual
`Build and test` run ID produced with `kernel_tests=false` plus the matching
`Reproducibility` run ID. It verifies the seven build jobs, exact six CI
artifacts, all thirteen reproducibility jobs, and exact eight reproducibility
artifacts. Publication uses the same two-phase digest protocol as a verified
release. Its release-set metadata records `kernel_validation=unverified`; the
validation state is deliberately not encoded in registry tags. These are
reproducible build outputs targeting the selected kernels, not kernel-tested
releases.

For a kernel-verified publication, dispatch `Publish release` from the same
`main` commit and supply both prerequisite run IDs:

- `ci_run_id`: a successful manual `Build and test` run with exact-kernel
  validation enabled; and
- `repro_run_id`: a successful manual `Reproducibility` run.

The verified release gate verifies that both IDs belong to successful
`workflow_dispatch` runs on `main` at the release workflow's full
`github.sha`. It requires the exact complete nine-job CI set (plan, four
product builds, two builder builds, and two exact-kernel jobs) and the exact
complete thirteen-job reproducibility set (plan, eight replica builds, and four
comparisons). Every job must be successful. It also requires the exact,
non-expired set of six CI artifacts and eight reproducibility artifacts.
Publish before the 14-day retention period expires. If `main` has advanced
since the prerequisite runs, rerun both gates at the new commit; v1
deliberately has no older-commit or tag release bypass.

Publishing performs no build and uses a two-phase registry protocol. Each
product job downloads the exact CI archives and one replica from the validated
reproducibility run, proves that the CI `workdir` is byte-for-byte identical to
that replica, checks transfer hashes, and smoke-tests the loaded images before
registry login. Builder jobs perform the corresponding transfer and image
checks. The jobs then push only run-specific `_staging-<release-run-id>-...`
tags and upload metadata containing the 14 staged manifest digests and their
exact and version-alias references. A single promotion job starts only after
all six staging jobs succeed, validates the complete metadata/reference
contract, and records it as `release-set.v2.json`. The release set also records
`kernel_validation=verified` or `kernel_validation=unverified` as appropriate.

Before writing any release tag, promotion resolves every staging digest and
preflights the complete tag set. An existing exact tag is accepted only when
its digest is identical; a different digest aborts the release. Exact tags are
created registry-side from the staged digest, while the corresponding
revision-less version aliases are controlled moving pointers. The tested
images are neither rebuilt nor pulled and repushed. The builder, carrier, and
runtime images are conventional Docker images. The verified `workdir` is
additionally staged and promoted with ORAS, but that OCI artifact is optional
and is not needed by the Docker-only air-gap workflow.

OCI Distribution does not provide a transaction spanning these repositories,
so the final tag writes cannot be literally atomic. A registry or network
failure during promotion can leave a prefix of release tags present. Treat a
release as complete only when the `promote` job succeeds; its final pass
resolves both tags for all 14 staged digests. Promotion is retry-safe:
identical exact tags are kept, missing exact tags are filled in, version aliases
are set to the expected digest, and any conflicting immutable tag is rejected.
The registry has no conditional multi-tag commit, so repository permissions,
the workflow concurrency lock, and the protected release environment must also
exclude an out-of-band publisher during the short check/write interval.
Run-specific staging tags are retained for audit/recovery and may be garbage
collected only after the complete tag set has been independently verified.

Every published digest receives two concise tags. The exact tag includes the
packaging revision and is immutable; the version alias omits that revision and
may move to a later packaging revision of the same upstream versions:

```text
# OVS runtime, DEB carrier, and OCI bundle
3.7.1-r1-ubuntu24.04-amd64
3.7.1-ubuntu24.04-amd64

# OVN runtime, DEB carrier, and OCI bundle
26.03.2-ovs3.7.1-r1-ubuntu24.04-amd64
26.03.2-ovs3.7.1-ubuntu24.04-amd64

# Builder
ovn26.03.2-ovs3.7.1-r1-ubuntu24.04-amd64
ovn26.03.2-ovs3.7.1-ubuntu24.04-amd64
```

Ubuntu 22.04 uses the corresponding `ubuntu22.04` forms. The publication
prefix is fixed to
`ghcr.io/<lowercase-repository-owner>/ovn-builder`; workflow inputs cannot
redirect publication to another registry namespace. The manifest digest is
the authoritative registry identity. Use the immutable exact tag plus its
digest for release and air-gap records; the moving alias is a convenience and
must not be used for approval. No `latest` tag is published. The full source
commit remains in release metadata, image labels, and OCI annotations. Third-party Actions
remain pinned to full commit SHAs. Keep the `build-only-publication`,
`kernel-validation`, and `release` environments protected, and provision any
future exact-kernel runners as single-use machines.

Build-only and kernel-verified publication normally come from separate CI
runs. If an exact tag was already published and a later verified run produces
a different image digest, promotion stops instead of replacing it. Increment
the packaging revision (`r1` to `r2`) for that verified image set; the
revision-less aliases can then move to the new digests.
Promotion also confirms that its source commit is still the protected `main`
head, preventing a rerun of an older workflow from rolling aliases backward.
