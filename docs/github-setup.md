# GitHub, GHCR, and ORAS setup

The repository has one publication path. `Publish release` promotes the exact
Docker archives and bundle bytes produced by CI; it does not rebuild during
publication. The registry prefix is fixed to
`ghcr.io/<lowercase-repository-owner>/ovn-builder`.

Publication requires two successful runs at the same current `main` commit:

- `Build and test`, produced by the automatic `main` push or a manual dispatch;
  and
- the manually dispatched `Reproducibility` workflow.

## Repository settings

Enable GitHub Actions, set the default `GITHUB_TOKEN` workflow permission to
read-only, and leave **Allow GitHub Actions to create and approve pull
requests** disabled. Do not enable write tokens for workflows from fork pull
requests. Publication jobs elevate only `packages: write`; other jobs use the
minimum read permissions they need.

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
the normal plan, build, builder, and package-consistency checks, and block
force pushes and deletion.

## Release environment

Create one environment named `release` and restrict deployment branches to
protected `main`. Add required reviewers and enable prevention of self-review
where the account plan supports it.

Environment secrets are not required. The workflow authenticates to GHCR with
the short-lived repository `GITHUB_TOKEN`; do not create a registry PAT for
Actions.

## Publication sequence

All three workflows must use the same current `main` commit:

1. Select a successful `Build and test` run. The automatic run created by the
   `main` push is acceptable; manually dispatch the workflow only when a fresh
   run is needed. Record its run ID after all nine jobs succeed.
2. Manually run `Reproducibility` and record its run ID after all thirteen jobs
   succeed.
3. Dispatch `Publish release` and supply those IDs as `ci_run_id` and
   `repro_run_id`.
4. Approve the `release` environment deployment.
5. Treat publication as complete only after `promote` resolves both public
   tags for all fourteen staged digests.

The required `Build and test` jobs are:

```text
plan
build / ovs-u2204
build / ovs-u2404
build / ovn-u2204
build / ovn-u2404
builder / u2204
builder / u2404
package-consistency / u2204
package-consistency / u2404
```

They produce exactly six 14-day artifacts:

```text
debs-ovs-u2204
debs-ovs-u2404
debs-ovn-u2204
debs-ovn-u2404
builder-u2204
builder-u2404
```

The required `Reproducibility` run has one plan job, eight no-cache replica
builds, and four comparison jobs. It produces exactly eight 14-day artifacts,
named `repro-<cell>-a` and `repro-<cell>-b` for the four product cells.

The release gate checks both run identities, their full job sets, and their
exact non-expired artifact sets. It requires the same repository, `main`
branch, and full commit as the publication run. Run publication before the
14-day inputs expire. If `main` advances, create new prerequisite runs at the
new commit.

Publishing stages four product groups and two builders, then promotes them in
one final job. The resulting `release-set.v3.json` records the fourteen content
digests and twenty-eight public references. The four canonical bundles use
`manifest.v2.json`, and their ORAS manifests use artifact type
`application/vnd.ovn-builder.deb-bundle.v2`.

## Published tags

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

Ubuntu 22.04 uses the corresponding `ubuntu22.04` forms. There is no `latest`
tag. Treat the resolved manifest digest as authoritative and record it with the
immutable exact tag. Do not use a moving alias as an approval identity.

Before writing any public tag, promotion resolves all staged digests and
preflights the full tag set. It refuses to replace an immutable exact tag at a
different digest. Immediately before promotion, it also confirms that the
publication commit is still the protected `main` head. Retry fills missing
exact tags and restores moving aliases only when the complete contract remains
valid.

Use `docker pull` for the builder, runtime, and conventional DEB carriers. Use
ORAS for the optional package artifacts:

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
this repository and the full source commit in
`org.opencontainers.image.revision`, so GHCR can associate and trace the
packages. After the first successful push, inspect each package's settings:

- confirm this repository has Actions write access or inherited access;
- choose public or private visibility explicitly, because GHCR does not make a
  package public merely because its source repository is public; and
- if public air-gap consumers need anonymous pulls, set every required package
  to public rather than exposing only the runtime image.

If a new release would change the digest behind an existing exact tag,
increment the packaging revision. Promotion then creates new exact tags and
may move the revision-less aliases after every staged object passes validation.
