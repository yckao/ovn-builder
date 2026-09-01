#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$root"

command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }
jq -e . release-lock.json >/dev/null
jq -e . .github/ci-matrix.json >/dev/null
jq -e '
  .schema == "io.ovn-builder.ci-toolchain-lock.v1" and
  .buildx_version == "v0.36.1" and
  .buildkit_image == "moby/buildkit:v0.32.2@sha256:28a898719c18a33f4e8000685287fa36fd0dd9560c6440227d3a732d79bb41d8" and
  .oras_version == "1.3.0"
' .github/toolchain-lock.json >/dev/null

jq -e '
  .schema == "io.ovn-builder.release-lock.v1" and
  .sources.ovs.version == "3.7.1" and
  .sources.ovs.commit == "7921d9c6924b8934ea1de9481891ac1172649280" and
  .sources.ovn.version == "26.03.2" and
  .sources.ovn.commit == "3facc3b5e99ba2c863ec5f47f37466397f735802" and
  .sources.ovn.build_ovs_commit == .sources.ovs.commit and
  .build_jobs == 4 and
  .features.dpdk == false and
  .features.lto == false and
  .features.debug_symbols == false and
  .packaging_patches == [{path:"patches/ovs/0001-reproducible-source-tar.patch",sha256:"84ef45be776a10b229da0b4eb27cc3cb53e12ef2a25a6aa8324e2423f733f981",purpose:"Normalize the embedded openvswitch-source tar created after dh_autoreconf"}] and
  .ubuntu["22.04"].kernel.release == "6.8.0-52-generic" and
  .ubuntu["24.04"].kernel.policy == "server-ga-linux-generic"
' release-lock.json >/dev/null

while IFS=$'\t' read -r path expected; do
  [[ -f $path ]] || { echo "locked patch is missing: $path" >&2; exit 1; }
  actual=$(sha256sum "$path" | cut -d' ' -f1)
  [[ $actual == "$expected" ]] || { echo "locked patch checksum mismatch: $path" >&2; exit 1; }
done < <(jq -r '.packaging_patches[] | [.path,.sha256] | @tsv' release-lock.json)

jq -e --slurpfile release release-lock.json '
  (.cells | length) == 4 and
  ([.cells[].id] | unique | length) == 4 and
  ([.cells[].product] | unique | sort) == ["ovn", "ovs"] and
  ([.cells[].ubuntu] | unique | sort) == ["22.04", "24.04"] and
  (.builders | length) == 2 and
  ([.builders[].id] | unique | length) == 2 and
  ([.builders[].ubuntu] | sort) == ["22.04", "24.04"] and
  (.kernels | length) == 2 and
  all(.kernels[];
    .ubuntu as $ubuntu |
    .ovs_artifact == ("debs-ovs-" + .distro) and
    .ovn_artifact == ("debs-ovn-" + .distro) and
    .expected_uname == $release[0].ubuntu[$ubuntu].kernel.release)
' .github/ci-matrix.json >/dev/null

while IFS= read -r script; do
    bash -n "$script"
done < <(find scripts -type f -name '*.sh' ! -path 'scripts/apt/*' ! -path 'scripts/runtime/policy-rc.d' | sort)
sh -n scripts/apt/configure-snapshot.sh
sh -n scripts/runtime/policy-rc.d

if command -v docker >/dev/null && docker buildx version >/dev/null 2>&1; then
    docker buildx bake --print \
        default \
        all-images \
        provenance-ovs-u2204 \
        provenance-ovs-u2404 \
        provenance-ovn-u2204 \
        provenance-ovn-u2404 \
        >/tmp/ovn-builder-bake-plan.json
    jq -e \
      --slurpfile plan /tmp/ovn-builder-bake-plan.json \
      --slurpfile lock release-lock.json '
      def expected_args($release; $ubuntu):
        ($release.ubuntu[$ubuntu]) as $target |
        {
          OVS_VERSION: $release.sources.ovs.version,
          OVS_COMMIT: $release.sources.ovs.commit,
          OVS_TARBALL_URL: $release.sources.ovs.tarball,
          OVS_TARBALL_SHA256: $release.sources.ovs.tarball_sha256,
          OVN_VERSION: $release.sources.ovn.version,
          OVN_COMMIT: $release.sources.ovn.commit,
          OVN_UPSTREAM_OVS_GITLINK: $release.sources.ovn.upstream_ovs_gitlink,
          SOURCE_DATE_EPOCH: ($release.source_date_epoch | tostring),
          BUILD_JOBS: ($release.build_jobs | tostring),
          UBUNTU_BASE: $target.base_image,
          UBUNTU_VERSION: $ubuntu,
          UBUNTU_CODENAME: $target.codename,
          APT_SNAPSHOT: $release.apt_snapshot,
          CA_CERTIFICATES_URL: $target.ca_certificates.url,
          CA_CERTIFICATES_SHA256: $target.ca_certificates.sha256,
          TARGET_KERNEL: $target.kernel.release,
          KERNEL_PACKAGE_VERSION: $target.kernel.package_version
        };
      def target_matches($name; $expected):
        $plan[0].target[$name] as $actual |
        $actual != null and
        $actual.platforms == ["linux/amd64"] and
        ($expected | to_entries) as $entries |
        all($entries[]; $actual.args[.key] == .value);

      $lock[0] as $release |
      all(.cells[];
        expected_args($release; .ubuntu) as $expected |
        target_matches(.debs_target; $expected) and
        target_matches(.carrier_target; $expected) and
        target_matches(.runtime_target; $expected) and
        target_matches("provenance-" + .product + "-" + .distro; $expected) and
        $plan[0].group[.images_target] != null) and
      all(.builders[];
        expected_args($release; .ubuntu) as $expected |
        target_matches(.builder_target; $expected))
    ' .github/ci-matrix.json >/dev/null
else
    echo "warning: Docker Buildx unavailable; skipped Bake parsing" >&2
fi

if [[ -d .github/workflows ]]; then
    while IFS= read -r workflow; do
        if grep -Eq 'uses: [^#[:space:]]+@(v[0-9]+|main|master)([[:space:]]|$)' "$workflow"; then
            echo "workflow contains a floating action reference: $workflow" >&2
            exit 1
        fi
    done < <(find .github/workflows -type f \( -name '*.yml' -o -name '*.yaml' \) | sort)
fi

buildx_version=$(jq -r '.buildx_version' .github/toolchain-lock.json)
buildkit_image=$(jq -r '.buildkit_image' .github/toolchain-lock.json)
oras_version=$(jq -r '.oras_version' .github/toolchain-lock.json)
[[ $(grep -Fc "version: $buildx_version" .github/workflows/ci.yml) == 2 ]] \
    || { echo "CI Buildx version pins do not match the toolchain lock" >&2; exit 1; }
[[ $(grep -Fc "image=$buildkit_image" .github/workflows/ci.yml) == 2 ]] \
    || { echo "CI BuildKit image pins do not match the toolchain lock" >&2; exit 1; }
[[ $(grep -Fc "version: $buildx_version" .github/workflows/reproducibility.yml) == 1 ]] \
    || { echo "reproducibility Buildx version pin does not match the toolchain lock" >&2; exit 1; }
[[ $(grep -Fc "image=$buildkit_image" .github/workflows/reproducibility.yml) == 1 ]] \
    || { echo "reproducibility BuildKit image pin does not match the toolchain lock" >&2; exit 1; }
[[ $(grep -Fc "version: $oras_version" .github/workflows/release.yml) == 3 ]] \
    || { echo "release ORAS version pins do not match the toolchain lock" >&2; exit 1; }
if [[ -f .github/workflows/publish-build-only.yml ]]; then
    [[ $(grep -Fc "version: $oras_version" .github/workflows/publish-build-only.yml) == 3 ]] \
        || { echo "build-only ORAS version pins do not match the toolchain lock" >&2; exit 1; }
fi

echo "release lock, CI toolchain, matrix, scripts and Bake definition are valid"
