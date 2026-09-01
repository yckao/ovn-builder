# Air-gapped delivery with a conventional Docker image

Version 1 supports environments that approve Docker images but do not accept
standalone OCI artifacts or arbitrary package archives. The carrier is an
ordinary Docker image based on the matching, digest-pinned Ubuntu release. Its
payload is `/workdir`.

The carrier is transport, not an installer and not a daemon image. The separate
`ovs` and `ovn` runtime images contain installed packages. The optional ORAS
artifact published by the release workflow is an additional distribution
format and is not used by the procedure in this document.

## Carrier contract

The v1 carrier has these properties:

- `/workdir` contains the exact canonical bundle exported by the corresponding
  `debs-*` Bake target;
- `io.ovn-builder.payload.path=/workdir` identifies the payload;
- `io.ovn-builder.bundle.schema=1` and
  `io.ovn-builder.bundle.profile=generated-only` identify its contract;
- the configured user is `65534:65534`;
- the image has no declared `VOLUME`, because a volume at `/workdir` would hide
  the packaged files;
- its default command is
  `sha256sum --check --strict SHA256SUMS`; and
- verification needs no network and writes no container filesystem state.

The payload layout is:

```text
/workdir/
  *.deb
  SHA256SUMS
  manifest.v1.json
  metadata/
    source-lock.json
    ovs/
    ovn/                 # present in an OVN carrier
```

An `ovs-debs` carrier contains generated OVS packages. An `ovn-debs` carrier
contains both generated OVN packages and the selected OVS packages needed for
the supported pairing.

## Image names

The default v1 carrier tags are:

```text
local/ovn-builder/ovs-debs:3.7.1-r1-ubuntu22.04-amd64
local/ovn-builder/ovs-debs:3.7.1-r1-ubuntu24.04-amd64
local/ovn-builder/ovn-debs:26.03.2-ovs3.7.1-r1-ubuntu22.04-amd64
local/ovn-builder/ovn-debs:26.03.2-ovs3.7.1-r1-ubuntu24.04-amd64
```

The `local/ovn-builder` prefix is configurable with `IMAGE_PREFIX`. The tag is
descriptive, not a trust root. An approval record should include the full tag,
the published registry digest when applicable, the image ID after loading, the
release-lock digest recorded in the bundle manifest, and the checksum of the
exact transfer archive.

Do not combine package sets for different OVS versions under one tag or in one
offline APT repository. Do not use `latest` for an approved transfer.

Version 1 also preserves the upstream Debian versions (`3.7.1-1` and
`26.03.2-1`) in both Ubuntu lanes. Jammy and Noble packages can therefore have
the same filename and dpkg version while containing different target-specific
bytes and dependencies. Keep the two Ubuntu outputs in separate directories,
images, approval records, and APT repositories; never select one by version
alone. If that same version is already installed, use the site's approved
same-version reinstall procedure and verify the carrier/DEB hashes rather than
letting APT treat the installed version as sufficient. A later packaging
revision should add a locked distro-specific Debian revision suffix.

## Build the carrier on the connected side

Build and load only a carrier:

```console
$ IMAGE_PREFIX=local/ovn-builder \
    docker buildx bake --load carrier-ovn-u2204
```

Alternatively, build the carrier and matching runtime together:

```console
$ make images TARGET=images-ovn-u2204
```

Replace `ovn` with `ovs` and `u2204` with `u2404` for another curated matrix
cell. These are amd64 release targets.

Set the exact image name and verify the embedded payload before export:

```console
$ IMAGE=local/ovn-builder/ovn-debs:26.03.2-ovs3.7.1-r1-ubuntu22.04-amd64
$ docker run --rm --pull=never --network=none --read-only \
    --cap-drop=ALL --security-opt=no-new-privileges "$IMAGE"
```

That command executes only the carrier's checksum verifier as its configured
unprivileged user. For full manifest and DEB metadata validation, extract into
a new directory and run the repository verifier:

```console
$ ./scripts/bundle/extract-image.sh "$IMAGE" ./checked-ovn-u2204
```

The helper refuses an existing destination, verifies carrier labels, runs the
in-image checksum command without network or writable rootfs, copies from a
stopped container, validates the copied tree, and publishes the destination
only after all checks pass.

## Save for transfer

Create one archive per approved image. A single-image archive makes the
approval subject and failure handling unambiguous.

```console
$ mkdir -p transfer
$ docker image save --output \
    transfer/ovn-26.03.2-ovs3.7.1-r1-ubuntu22.04-amd64.docker.tar \
    "$IMAGE"
$ cd transfer
$ sha256sum \
    ovn-26.03.2-ovs3.7.1-r1-ubuntu22.04-amd64.docker.tar \
    > TRANSFER-SHA256SUMS
```

Preserve `TRANSFER-SHA256SUMS` in the approved transfer record. The CI build
artifacts use the same pattern for carrier and runtime archives.

The tar checksum provides transport integrity for this particular saved file.
It is not a claim that two independent `docker save` operations produce the
same tar bytes. The published image digest and the bundle's internal hashes are
the stable content identities.

## Verify and load inside the air gap

First verify the archive before asking Docker to parse it:

```console
$ cd transfer
$ sha256sum --check --strict TRANSFER-SHA256SUMS
$ docker image load --input \
    ovn-26.03.2-ovs3.7.1-r1-ubuntu22.04-amd64.docker.tar
```

Set `IMAGE` to the exact loaded tag and inspect the contract:

```console
$ IMAGE=local/ovn-builder/ovn-debs:26.03.2-ovs3.7.1-r1-ubuntu22.04-amd64
$ docker image inspect --format '{{.Id}}' "$IMAGE"
$ docker image inspect --format \
    '{{index .Config.Labels "io.ovn-builder.payload.path"}}' "$IMAGE"
$ docker image inspect --format \
    '{{index .Config.Labels "io.ovn-builder.bundle.profile"}}' "$IMAGE"
```

The last two commands must print `/workdir` and `generated-only`. Compare the
image ID and, when preserved by the transport, the repository digest with the
approval record. Then verify the original embedded tree:

```console
$ docker run --rm --pull=never --network=none --read-only \
    --cap-drop=ALL --security-opt=no-new-privileges "$IMAGE"
```

`--pull=never` prevents an unexpected registry lookup, and `--network=none`
makes the no-network property explicit.

## Extract without executing package contents

When this repository's scripts and their host dependencies are available, use
the hardened helper:

```console
$ DEST=$PWD/imported/ovn-u2204
$ ./scripts/bundle/extract-image.sh "$IMAGE" "$DEST"
$ ./scripts/bundle/verify.sh "$DEST"
```

`DEST` must not already exist. The verifier requires Bash, GNU coreutils, GNU
findutils, `jq`, and `dpkg-deb` on the host.

If policy allows only the Docker image to cross the boundary and the helper is
not present, use Docker's stopped-container copy operation. The following
sequence does not start the container:

```bash
set -eu

image=local/ovn-builder/ovn-debs:26.03.2-ovs3.7.1-r1-ubuntu22.04-amd64
dest="$PWD/imported/ovn-u2204"
parent=$(dirname -- "$dest")
test ! -e "$dest"
mkdir -p -- "$parent"
tmp=$(mktemp -d "$parent/.ovn-bundle.XXXXXX")
cid=

cleanup() {
    if test -n "$cid"; then
        docker container rm -f "$cid" >/dev/null 2>&1 || true
    fi
    if test -n "$tmp" && test -d "$tmp"; then
        rm -rf -- "$tmp"
    fi
}
trap cleanup EXIT HUP INT TERM

cid=$(docker container create --pull=never --network=none "$image")
docker container cp "$cid:/workdir/." "$tmp/"
docker container rm "$cid" >/dev/null
cid=

(
    cd "$tmp"
    sha256sum --check --strict SHA256SUMS
)
mv -- "$tmp" "$dest"
tmp=
trap - EXIT HUP INT TERM
```

Run `scripts/bundle/verify.sh` later if the full verification toolchain becomes
available. The plain sequence verifies the copied bytes but does not repeat the
manifest-versus-`dpkg-deb` checks performed by the hardened helper.

Do not bind-mount an empty directory over `/workdir` to extract the payload;
the mount hides the image contents. `docker cp` from a stopped container is the
intended mechanism.

## Generated-only means generated-only

The v1 carrier deliberately includes only project packages and build metadata.
Only deterministic build metadata is included; dpkg's per-run `.buildinfo`
and `.changes` records are outside this reproducible payload because they
contain or transitively hash a wall-clock build date.
It does **not** include:

- every transitive Ubuntu `Pre-Depends` or `Depends` package;
- APT `Packages`, `Release`, or signature metadata;
- an Ubuntu mirror or snapshot service;
- a generic production installer; or
- proof that the package works with a kernel merely named in its manifest.

Consequently, copying the DEBs into an isolated machine is not sufficient to
guarantee installation. The target must already contain the dependencies or
have access to an approved Ubuntu repository compatible with the target release
and architecture. Use the package names and exact versions in
`manifest.v1.json` with the site's normal package-management and change-control
process. Do not assume that `dpkg -i *.deb` can resolve dependencies.

The runtime image is independently useful in a Docker-only environment because
its dependencies were installed when the image was built. It is not an offline
APT mirror from which a host can install the carrier's DEBs.

## Planned full-offline profile

A later profile can retain the normal Docker carrier while adding a complete,
target-specific APT repository. It should use a distinct immutable tag suffix,
such as `-offline-r1`, and a manifest profile such as `full-offline`.

The planned layout is conventional APT repository content under `/workdir`:

```text
/workdir/
  repo/
    pool/
      project/             # generated OVN/OVS packages
      dependencies/        # exact Ubuntu dependency closure
    Packages
    Packages.xz
    Release                # when deterministic release metadata is enabled
    Release.gpg            # when an approved repository key is enabled
  manifest.v1.json
  SHA256SUMS
  metadata/
```

The dependency closure must be solved in a clean environment for the exact
Ubuntu snapshot and architecture, include `Pre-Depends` and `Depends`, and make
the `Recommends` policy explicit. Each dependency needs its package identity,
version, origin snapshot, size, and checksum in the manifest. Offline CI must
install using only a temporary `file:` source with all network access disabled.

APT indexes must be generated with pinned tools, stable ordering and locale,
fixed timestamps, and deterministic compression. Repository signatures need an
approved key and a controlled signing procedure. Until that implementation and
its network-disabled install test exist, a carrier remains `generated-only` and
must not be advertised as a complete offline repository.

OVS 3.7.1 and a future OVS 4.0 package set must remain in different carrier
images and repositories. Otherwise APT can choose the numerically higher
version and bypass the intended OVN/OVS compatibility pairing.

## Kernel validation in an air-gapped environment

The carrier's `io.ovn-builder.target-kernel` label and the manifest's
`expected_kernel` field describe the intended compatibility target. They are
static build metadata, not evidence that the kernel was booted, and they do not
cause that kernel to run inside the carrier. A registry tag containing
`kernel-unverified` explicitly identifies a build-only publication.

Containers share the Docker host's kernel. Loading `openvswitch`, validating
its vermagic, and exercising datapath operations therefore require a VM or
machine booted into the target kernel:

- Ubuntu 22.04: exactly `6.8.0-52-generic` for the v1 compatibility target;
- Ubuntu 24.04: the GA server kernel locked by this release, currently
  `6.8.0-138-generic`.

The repository's exact-kernel CI script first compares `uname -r`, then loads
the distribution `openvswitch` module. It installs OVS DEBs from the standalone
OVS carrier and only OVN DEBs from the combined OVN carrier, with package
service autostart temporarily inhibited. The bounded functional test starts
the systemd-managed OVS, OVN central, and OVN host services; verifies the NB/SB
databases and `ovn-northd`; registers a chassis; binds a logical port through
an internal `br-int` interface; and confirms controller-installed flows. It
then removes the test topology and stops services that were not active before
the test. Reproduce those semantics on an isolated, single-use test VM before
promoting a package set. A normal container smoke test is not a substitute.
The VM must not depend on OVS for its management network; the test requires the
OVS and OVN services to be inactive at entry and refuses to reuse an existing
`br-int` or OVN-specific OVS configuration.

## Validation summary

The release pipeline checks these distinct layers:

| Layer | Identity or check |
| --- | --- |
| Source/build inputs | `release-lock.json`, source commits, archive SHA-256, image digests, Ubuntu snapshot |
| Bundle payload | canonical `manifest.v1.json` plus `SHA256SUMS` and full host verifier |
| Carrier behavior | labels, non-root user, no volume, read-only/no-network checksum run, stopped-container extraction |
| Transfer | SHA-256 of the exact `docker save` archive before `docker load` |
| Runtime image | installed binary version smoke test |
| Kernel | separate VM/self-hosted test on the exact `uname -r` value |
| Reproducibility | two no-cache builds with byte-for-byte bundle comparison |

Keep all of those records with an air-gap approval. No single tag, checksum, or
container smoke test replaces the other layers.
