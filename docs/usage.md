# Using the published images and artifacts

The release publishes seven GHCR repositories. All current release images are
`linux/amd64`; use the tag for the Ubuntu release that will consume the DEBs.

```bash
REGISTRY=ghcr.io/yckao/ovn-builder
OVS_TAG=3.7.1-r1-ubuntu24.04-amd64
OVN_TAG=26.03.2-ovs3.7.1-r1-ubuntu24.04-amd64
BUILDER_TAG=ovn26.03.2-ovs3.7.1-r1-ubuntu24.04-amd64
```

For Ubuntu 22.04, replace `ubuntu24.04` with `ubuntu22.04` in each tag. The
tag containing `r1` is the immutable packaging-release tag. A second,
revision-less alias is also published by removing `-r1`, for example
`3.7.1-ubuntu24.04-amd64`; that alias may move to a later packaging revision.
There is no `latest` tag. Use the `r1` tag or, preferably, a digest for an
approval record or production deployment.

| Repository | Ubuntu 24.04 immutable tag | Purpose |
| --- | --- | --- |
| `builder` | `ovn26.03.2-ovs3.7.1-r1-ubuntu24.04-amd64` | Build tools and pinned OVS and OVN source trees |
| `ovs-debs` | `3.7.1-r1-ubuntu24.04-amd64` | Docker-compatible carrier containing OVS DEBs in `/workdir` |
| `ovn-debs` | `26.03.2-ovs3.7.1-r1-ubuntu24.04-amd64` | Docker-compatible carrier containing OVN and matching OVS DEBs in `/workdir` |
| `ovs-debs-oci` | `3.7.1-r1-ubuntu24.04-amd64` | The OVS bundle as an ORAS/OCI artifact |
| `ovn-debs-oci` | `26.03.2-ovs3.7.1-r1-ubuntu24.04-amd64` | The OVN and matching OVS bundle as an ORAS/OCI artifact |
| `ovs` | `3.7.1-r1-ubuntu24.04-amd64` | Ubuntu image with selected OVS runtime packages installed |
| `ovn` | `26.03.2-ovs3.7.1-r1-ubuntu24.04-amd64` | Ubuntu image with selected OVN and OVS runtime packages installed |

Public GHCR packages can be pulled anonymously. If the packages are private,
authenticate Docker and ORAS using a GitHub token with `read:packages`:

```bash
printf '%s' "$GHCR_TOKEN" | docker login ghcr.io --username YOUR_GITHUB_USER --password-stdin
printf '%s' "$GHCR_TOKEN" | oras login ghcr.io --username YOUR_GITHUB_USER --password-stdin
```

## Pin a conventional image by digest

Pull the immutable tag once and record the registry digest:

```bash
OVS_IMAGE="$REGISTRY/ovs:$OVS_TAG"
docker pull --platform linux/amd64 "$OVS_IMAGE"
OVS_PINNED=$(docker image inspect --format '{{index .RepoDigests 0}}' "$OVS_IMAGE")
printf '%s\n' "$OVS_PINNED"

# Subsequent pulls and runs can use ghcr.io/.../ovs@sha256:...
docker pull --platform linux/amd64 "$OVS_PINNED"
docker run --rm --pull=never --network=none "$OVS_PINNED"
```

The digest, rather than either tag, is the authoritative registry identity.
Record it alongside the tag. A tag does not state whether exact-kernel testing
was performed; that result is in the corresponding publication release-set
metadata.

## Docker DEB carriers: `ovs-debs` and `ovn-debs`

Use `ovs-debs` when only OVS packages are needed. Use `ovn-debs` when OVN is
needed; it also contains the matching OVS packages. A carrier's working
directory and payload location are both `/workdir`. Its default command does
not install anything: it runs strict verification of `SHA256SUMS` as the
unprivileged user `65534:65534`.

Pull and verify a carrier:

```bash
OVN_CARRIER="$REGISTRY/ovn-debs:$OVN_TAG"
docker pull --platform linux/amd64 "$OVN_CARRIER"
docker run --rm --pull=never --network=none --read-only \
  --cap-drop=ALL --security-opt=no-new-privileges "$OVN_CARRIER"
```

When this repository is available, use its extraction helper. The destination
must not already exist; the helper verifies the image labels, embedded hashes,
manifest, and DEB metadata before publishing the destination:

```bash
./scripts/bundle/extract-image.sh \
  "$OVN_CARRIER" "$PWD/extracted/ovn-u2404"
```

If only Docker is available, copy `/workdir` from a stopped container, then at
least verify its hashes:

```bash
mkdir -p extracted/ovn-u2404
cid=$(docker container create --pull=never --network=none "$OVN_CARRIER")
docker container cp "$cid:/workdir/." extracted/ovn-u2404/
docker container rm "$cid"
(cd extracted/ovn-u2404 && sha256sum --check --strict SHA256SUMS)
```

The copied directory contains:

```text
*.deb
SHA256SUMS
manifest.v1.json
metadata/
```

Install only the packages required for the selected role. The runtime images
are built with these package sets:

```bash
cd extracted/ovn-u2404

# OVS runtime package set
sudo apt-get install \
  ./openvswitch-common_*.deb \
  ./openvswitch-switch_*.deb \
  ./python3-openvswitch_*.deb

# Additional packages used by the OVN runtime image
sudo apt-get install \
  ./ovn-common_*.deb \
  ./ovn-host_*.deb \
  ./ovn-central_*.deb
```

Run those commands only on the matching Ubuntu release and architecture. The
carrier has the generated project DEBs, not a complete offline Ubuntu
dependency repository. A disconnected target must already have the required
dependencies or use a separately approved Ubuntu dependency source. Jammy and
Noble DEBs must remain separate even when their Debian package versions look
identical. If the same version is already installed, follow the
[same-version replacement precautions](airgap.md#image-names) rather than
assuming APT selected the carrier's bytes.

## Runtime images: `ovs` and `ovn`

These are package-installed Ubuntu base images, not preconfigured appliances.
They are not systemd or multi-daemon supervisors. With no command override
they print a version and exit:

```bash
OVS_RUNTIME="$REGISTRY/ovs:$OVS_TAG"
OVN_RUNTIME="$REGISTRY/ovn:$OVN_TAG"

docker pull --platform linux/amd64 "$OVS_RUNTIME"
docker run --rm --pull=never --network=none --read-only \
  --cap-drop=ALL --security-opt=no-new-privileges "$OVS_RUNTIME"
# Runs: /usr/sbin/ovs-vswitchd --version

docker pull --platform linux/amd64 "$OVN_RUNTIME"
docker run --rm --pull=never --network=none --read-only \
  --cap-drop=ALL --security-opt=no-new-privileges "$OVN_RUNTIME"
# Runs: /usr/bin/ovn-controller --version
```

There is no entrypoint, so an explicit command replaces the version command.
For example:

```bash
docker run --rm --pull=never --network=none \
  --read-only --cap-drop=ALL --security-opt=no-new-privileges \
  "$OVS_RUNTIME" /usr/bin/ovs-vsctl --version
docker run --rm --pull=never --network=none \
  --read-only --cap-drop=ALL --security-opt=no-new-privileges \
  "$OVN_RUNTIME" /usr/bin/ovn-nbctl --version
docker run --rm -it --pull=never --entrypoint /bin/bash "$OVN_RUNTIME"
```

For a normal host installation, extract the matching carrier and install its
DEBs through the host's approved package-management workflow. Use these
runtime images as bases only when a separate deployment supplies the complete
service configuration and lifecycle.

Running `ovs-vswitchd`, `ovsdb-server`, `ovn-controller`, or `ovn-northd` as a
service additionally requires role-specific databases, state directories,
sockets, configuration and networking. OVS kernel-datapath use also depends on
the host kernel and normally requires carefully selected capabilities and host
resources. Containers share the host kernel: the kernel named in an image
label is a build/test target, not a kernel bundled in the image. Do not turn a
version command into a privileged daemon by blindly adding `--privileged`;
define the required mounts, devices and least-privilege capabilities in the
deployment that owns those services.

The locked target kernels for this packaging release are
`6.8.0-52-generic` on Ubuntu 22.04 and `6.8.0-138-generic` on Ubuntu 24.04.
Check the publication release-set before relying on exact-kernel validation.

## Builder image: `builder`

The builder defaults to `/bin/bash` in `/workspace`. It contains the complete
build dependency set, the release lock, and these source and helper paths:

```text
/usr/src/openvswitch
/usr/src/ovn
/usr/share/ovn-builder/release-lock.json
/usr/local/libexec/ovn-builder/build-ovs-debs.sh
/usr/local/libexec/ovn-builder/build-ovn-debs.sh
```

Open an interactive shell:

```bash
BUILDER="$REGISTRY/builder:$BUILDER_TAG"
docker pull --platform linux/amd64 "$BUILDER"
docker run --rm -it --pull=never --network=none \
  --platform linux/amd64 "$BUILDER"
```

Copy the locked source trees out without running the container:

```bash
mkdir -p source
cid=$(docker container create --pull=never "$BUILDER")
docker container cp "$cid:/usr/src/openvswitch" source/openvswitch
docker container cp "$cid:/usr/src/ovn" source/ovn
docker container rm "$cid"
```

The helpers require new output directories and use the build environment
already recorded in the image. Run each build in a fresh container because the
build modifies its source tree. Bind-mounted results are normally owned by
root because the build runs as root:

```bash
mkdir -p "$PWD/build-output"

# Build OVS DEBs and deterministic build metadata.
docker run --rm --pull=never --network=none --platform linux/amd64 \
  --mount type=bind,source="$PWD/build-output",target=/workspace/output \
  --entrypoint /bin/bash "$BUILDER" -ceu '
    /usr/local/libexec/ovn-builder/build-ovs-debs.sh \
      /usr/src/openvswitch /workspace/output/ovs
  '

# Build OVN DEBs against the locked OVS source. This creates OVN output only;
# use the separate OVS build above when both package sets are required.
docker run --rm --pull=never --network=none --platform linux/amd64 \
  --mount type=bind,source="$PWD/build-output",target=/workspace/output \
  --entrypoint /bin/bash "$BUILDER" -ceu '
    /usr/local/libexec/ovn-builder/build-ovn-debs.sh \
      /usr/src/ovn /usr/src/openvswitch \
      /workspace/ovs-for-ovn /workspace/output/ovn
  '
```

For the complete canonical bundle with `manifest.v1.json` and `SHA256SUMS`,
use the repository's Bake target instead of calling a package helper directly:

```bash
make debs TARGET=debs-ovn-u2404
./scripts/bundle/verify.sh dist/ovn/u2404
```

The alternatives are `debs-ovs-u2404`, `debs-ovn-u2204`, and
`debs-ovs-u2204`.

## ORAS package artifacts: `ovs-debs-oci` and `ovn-debs-oci`

These repositories contain the same canonical bundle files as the Docker
carriers, but as OCI artifacts. They are not runnable Docker images. Resolve
the tag, record its digest, and pull by that digest into an empty directory:

```bash
OVN_OCI_REPO="$REGISTRY/ovn-debs-oci"
OVN_OCI_TAGGED="$OVN_OCI_REPO:$OVN_TAG"
OVN_OCI_DIGEST=$(oras resolve "$OVN_OCI_TAGGED")
printf '%s@%s\n' "$OVN_OCI_REPO" "$OVN_OCI_DIGEST"

mkdir ovn-oci-u2404
(
  cd ovn-oci-u2404
  oras pull "$OVN_OCI_REPO@$OVN_OCI_DIGEST"
  sha256sum --check --strict SHA256SUMS
)
```

For OVS, use `ovs-debs-oci` and `$OVS_TAG`. Run
`scripts/bundle/verify.sh` on the pulled directory when the repository and its
verification dependencies are available. For an air gap that permits only
Docker images, use `ovs-debs` or `ovn-debs` instead.

## Save and load a Docker image for an air gap

The builder, runtime, and DEB carrier repositories are conventional Docker
images and can all use the same transfer flow. This example transfers the OVN
DEB carrier:

```bash
mkdir -p transfer
docker pull --platform linux/amd64 "$OVN_CARRIER"
docker image inspect --format '{{index .RepoDigests 0}}' "$OVN_CARRIER"
docker image save --output transfer/ovn-debs-u2404.docker.tar "$OVN_CARRIER"
(cd transfer && sha256sum ovn-debs-u2404.docker.tar > TRANSFER-SHA256SUMS)
```

Inside the air gap, verify the transfer archive before loading it:

```bash
(cd transfer && sha256sum --check --strict TRANSFER-SHA256SUMS)
docker image load --input transfer/ovn-debs-u2404.docker.tar
docker run --rm --pull=never --network=none --read-only \
  --cap-drop=ALL --security-opt=no-new-privileges "$OVN_CARRIER"
```

Keep the source registry digest, immutable tag, saved-archive checksum and
bundle checksums in the approval record. A `docker save` archive is a transport
serialization and its checksum is not a substitute for the registry digest or
the embedded `SHA256SUMS`.
