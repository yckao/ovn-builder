# GitHub, GHCR, and ORAS setup

The repository publishes through two validation paths:

- `Publish build-only` works without a self-hosted runner. It requires
  successful package/image builds and the complete two-replica reproducibility
  workflow. Its release set records `kernel_validation=unverified`.
- `Publish release` remains fail-closed until both exact-kernel jobs and the
  complete reproducibility workflow succeed for the same `main` commit. Its
  release set records `kernel_validation=verified`.

Both workflows promote the exact Docker archives and bundle bytes produced by
CI. They do not rebuild during publication. Kernel-validation state is release
metadata, not part of a registry tag. The registry prefix is fixed to
`ghcr.io/<lowercase-repository-owner>/ovn-builder`.

## Repository settings

Enable GitHub Actions, set the default `GITHUB_TOKEN` workflow permission to
read-only, and leave **Allow GitHub Actions to create and approve pull
requests** disabled. Do not enable write tokens for workflows from fork pull
requests. Publication jobs elevate only `packages: write`; validation jobs keep
`contents: read` and `actions: read`.

The workflows use only full-commit action references. If the repository uses
an Actions allowlist, permit these repositories:

- `actions/checkout`
- `actions/upload-artifact`
- `actions/download-artifact`
- `docker/setup-buildx-action`
- `docker/bake-action`
- `docker/login-action`
- `oras-project/setup-oras`

Protect `main` with a branch ruleset. Require pull requests and review, require
the normal build/product/builder checks, and block force pushes and deletion.
Do not make an exact-kernel job a merge requirement while no matching runner
exists; exact-kernel validation is a publication gate, not a build prerequisite.

## Environments

Create these environments and restrict deployment branches to protected
`main`:

| Environment | Purpose |
| --- | --- |
| `build-only-publication` | Approves reproducible publication without exact-kernel validation |
| `release` | Approves kernel-verified canonical publication |
| `kernel-validation` | Protects future exact-kernel self-hosted jobs |

Add required reviewers to both publication environments and enable prevention
of self-review where the account plan supports it. Environment secrets are not
required. The workflows authenticate to GHCR with the short-lived repository
`GITHUB_TOKEN`; do not create a registry PAT for Actions.

## First build-only publication

All three workflows must be dispatched from the same `main` commit:

1. Run `Build and test` with `kernel_tests=false`. Record its run ID after the
   four product jobs and two builder jobs succeed.
2. Run `Reproducibility`. Record its run ID after all eight no-cache builds and
   four comparison jobs succeed.
3. Run `Publish build-only` and supply those two run IDs.
4. Approve the `build-only-publication` environment deployment.
5. Treat the publication as complete only after its final `promote` job has
   resolved both published tags for all fourteen staged digests.

Each digest gets one immutable exact tag and one revision-less moving version
alias. The repository name identifies whether the object is a runtime image,
DEB carrier, OCI bundle, or builder, so that information is not repeated in the
tag:

```text
Repository group                   Exact tag                                         Version alias
ovs, ovs-debs, ovs-debs-oci        3.7.1-r1-ubuntu24.04-amd64                         3.7.1-ubuntu24.04-amd64
ovn, ovn-debs, ovn-debs-oci        26.03.2-ovs3.7.1-r1-ubuntu24.04-amd64              26.03.2-ovs3.7.1-ubuntu24.04-amd64
builder                            ovn26.03.2-ovs3.7.1-r1-ubuntu24.04-amd64           ovn26.03.2-ovs3.7.1-ubuntu24.04-amd64
```

Ubuntu 22.04 uses the corresponding `ubuntu22.04` forms.

Use `docker pull` for the runtime and conventional DEB carrier. Use ORAS for
the optional package artifact:

```console
$ oras pull ghcr.io/OWNER/ovn-builder/ovn-debs-oci:TAG
```

## GHCR package settings

The first publication creates seven GHCR package repositories:

```text
builder
ovs
ovs-debs
ovs-debs-oci
ovn
ovn-debs
ovn-debs-oci
```

Images and OCI artifacts carry `org.opencontainers.image.source` pointing at
this repository, plus the full source commit in
`org.opencontainers.image.revision`, so GHCR can associate and trace the
packages. After the first
successful push, inspect each package's settings:

- confirm this repository has Actions write access (or inherited access);
- choose public or private visibility explicitly; GHCR does not make new
  packages public merely because a workflow published them; and
- if public air-gap consumers need anonymous pulls, set every required package
  to public rather than exposing only the runtime image.

Build-only and verified publications use the same build-identity tag scheme;
their `kernel_validation` value is carried by the release-set metadata. Exact
tags are immutable, while revision-less version aliases may advance to a later
packaging revision of the same upstream versions. There is no `latest` tag.
Consumers should treat the resolved manifest digest as authoritative and record
it with the exact tag. Moving aliases must not be used for air-gap approval.

Build-only and kernel-verified publication use independent CI runs. If their
image digests differ, a verified publication must use a new packaging revision
instead of replacing an existing exact tag. Promotion fails closed on that
conflict; after the revision is incremented, the version aliases may move.
Immediately before promotion, the workflow also verifies that its full source
commit is still the current `main` head, so rerunning an obsolete workflow
cannot roll those aliases back.
