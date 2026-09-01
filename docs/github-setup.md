# GitHub, GHCR, and ORAS setup

The repository publishes two deliberately separate channels:

- `Publish build-only (kernel unverified)` works without a self-hosted runner.
  It requires successful package/image builds and the complete two-replica
  reproducibility workflow. Every canonical tag contains `kernel-unverified`.
- `Publish release` remains fail-closed until both exact-kernel jobs and the
  complete reproducibility workflow succeed for the same `main` commit.

Both workflows promote the exact Docker archives and bundle bytes produced by
CI. They do not rebuild during publication. The registry prefix is fixed to
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
| `build-only-publication` | Approves publication under visibly kernel-unverified tags |
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
3. Run `Publish build-only (kernel unverified)` and supply those two run IDs.
4. Approve the `build-only-publication` environment deployment.
5. Treat the publication as complete only after its final `promote` job has
   resolved all fourteen canonical digests.

Example reference forms are:

```text
ghcr.io/OWNER/ovn-builder/ovn:26.03.2-ovs3.7.1-r1-ubuntu22.04-amd64-kernel-unverified-FULL_SHA
ghcr.io/OWNER/ovn-builder/ovn-debs:26.03.2-ovs3.7.1-r1-ubuntu22.04-amd64-kernel-unverified-FULL_SHA
ghcr.io/OWNER/ovn-builder/ovn-debs-oci:26.03.2-ovs3.7.1-r1-ubuntu22.04-amd64-kernel-unverified-FULL_SHA
```

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
this repository so GHCR can associate the packages with it. After the first
successful push, inspect each package's settings:

- confirm this repository has Actions write access (or inherited access);
- choose public or private visibility explicitly; GHCR does not make new
  packages public merely because a workflow published them; and
- if public air-gap consumers need anonymous pulls, set every required package
  to public rather than exposing only the runtime image.

Build-only and verified publications share package repositories but never tag
names. There is no `latest` tag. Consumers should pin the resolved manifest
digest in addition to recording the full-SHA tag.
