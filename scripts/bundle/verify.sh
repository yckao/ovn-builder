#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
export LC_ALL=C TZ=UTC

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

(($# == 1)) || die "usage: verify.sh BUNDLE_DIR"
bundle=$1
[[ -d $bundle ]] || die "bundle directory not found: $bundle"
[[ -f $bundle/SHA256SUMS ]] || die "SHA256SUMS is missing"
[[ -f $bundle/manifest.v2.json ]] || die "manifest.v2.json is missing"

if find "$bundle" -type f \( -name '*.buildinfo' -o -name '*.changes' \) -print -quit | grep -q .; then
    die "volatile dpkg provenance is not allowed in a generated-only bundle"
fi

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
declare -A seen=()
: > "$tmp/checksum-paths"

while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^[0-9a-f]{64}\ \ \./[A-Za-z0-9._+~:/-]+$ ]] || die "unsafe checksum entry"
    path=${line:66}
    [[ $path == ./* ]] || die "checksum path is not relative"
    [[ $path != *'/../'* && $path != '../'* && $path != *'/..' ]] || die "checksum path traverses upward"
    [[ -z ${seen[$path]+x} ]] || die "duplicate checksum path: $path"
    seen[$path]=1
    [[ -f $bundle/${path#./} && ! -L $bundle/${path#./} ]] || die "invalid payload path: $path"
    printf '%s\n' "${path#./}" >> "$tmp/checksum-paths"
done < "$bundle/SHA256SUMS"

find "$bundle" -type f ! -name SHA256SUMS -printf '%P\n' | sort > "$tmp/files"
sort "$tmp/checksum-paths" -o "$tmp/checksum-paths"
cmp -s "$tmp/files" "$tmp/checksum-paths" || die "checksum file set does not match payload"

if find "$bundle" -mindepth 1 \! -type d \! -type f -print -quit | grep -q .; then
    die "bundle contains a symlink or special file"
fi

(cd "$bundle" && sha256sum --check --strict SHA256SUMS >/dev/null)

jq -e '
    .schema == "io.ovn-builder.deb-carrier.v2" and
    .profile == "generated-only" and
    (.product == "ovs" or .product == "ovn") and
    .payload_root == "/workdir" and
    (.target | keys | sort) == ["architecture", "codename", "ubuntu_version"] and
    (.packages | type == "array" and length > 0) and
    (.packages == (.packages | sort_by(.file))) and
    (([.packages[].file] | unique | length) == (.packages | length))
' "$bundle/manifest.v2.json" >/dev/null || die "manifest schema validation failed"

source_lock=$bundle/metadata/source-lock.json
[[ -f $source_lock && ! -L $source_lock ]] || die "embedded source lock is missing or unsafe"
source_lock_sha256=$(sha256sum "$source_lock" | cut -d' ' -f1)
jq -e \
    --arg source_lock_sha256 "$source_lock_sha256" \
    --slurpfile lock "$source_lock" '
      . as $manifest |
      $lock[0] as $release |
      $release.schema == "io.ovn-builder.release-lock.v2" and
      $manifest.build.release_lock_sha256 == $source_lock_sha256 and
      $manifest.build.source_date_epoch == $release.source_date_epoch and
      $manifest.build.apt_snapshot == $release.apt_snapshot and
      $manifest.target.architecture == $release.architecture and
      $manifest.build.dpdk == $release.features.dpdk and
      $manifest.build.lto == $release.features.lto and
      $manifest.build.debug_symbols == $release.features.debug_symbols and
      $manifest.source.ovs.version == $release.sources.ovs.version and
      $manifest.source.ovs.commit == $release.sources.ovs.commit and
      $manifest.source.ovn.version == $release.sources.ovn.version and
      $manifest.source.ovn.commit == $release.sources.ovn.commit and
      $manifest.source.ovn.upstream_ovs_gitlink == $release.sources.ovn.upstream_ovs_gitlink and
      $manifest.source.ovn.build_ovs_commit == $release.sources.ovn.build_ovs_commit and
      $manifest.target.codename == $release.ubuntu[$manifest.target.ubuntu_version].codename and
      $manifest.build.base_image == $release.ubuntu[$manifest.target.ubuntu_version].base_image and
      all($manifest.packages[];
        (.architecture == $manifest.target.architecture or .architecture == "all") and
        (.component == "ovs" or .component == "ovn")) and
      (if $manifest.product == "ovs" then
         all($manifest.packages[]; .component == "ovs")
       else
         any($manifest.packages[]; .component == "ovs") and
         any($manifest.packages[]; .component == "ovn")
       end)
    ' "$bundle/manifest.v2.json" >/dev/null \
    || die "manifest and embedded release lock disagree"

: > "$tmp/manifest-debs"
while IFS= read -r encoded; do
    item=$(printf '%s' "$encoded" | base64 -d)
    file=$(jq -r '.file' <<< "$item")
    [[ $file =~ ^[A-Za-z0-9][A-Za-z0-9.+_~:-]*\.deb$ ]] || die "unsafe manifest DEB filename"
    path=$bundle/$file
    [[ -f $path && ! -L $path ]] || die "manifest DEB is missing: $file"
    [[ $(sha256sum "$path" | cut -d' ' -f1) == $(jq -r '.sha256' <<< "$item") ]] || die "DEB checksum mismatch: $file"
    [[ $(stat -c '%s' "$path") == $(jq -r '.size' <<< "$item") ]] || die "DEB size mismatch: $file"
    [[ $(dpkg-deb -f "$path" Package) == $(jq -r '.package' <<< "$item") ]] || die "DEB package mismatch: $file"
    [[ $(dpkg-deb -f "$path" Version) == $(jq -r '.version' <<< "$item") ]] || die "DEB version mismatch: $file"
    [[ $(dpkg-deb -f "$path" Architecture) == $(jq -r '.architecture' <<< "$item") ]] || die "DEB architecture mismatch: $file"
    printf '%s\n' "$file" >> "$tmp/manifest-debs"
done < <(jq -r '.packages[] | @base64' "$bundle/manifest.v2.json")

find "$bundle" -maxdepth 1 -type f -name '*.deb' -printf '%f\n' | sort > "$tmp/payload-debs"
sort "$tmp/manifest-debs" -o "$tmp/manifest-debs"
cmp -s "$tmp/payload-debs" "$tmp/manifest-debs" || die "manifest DEB set does not match payload"

while IFS= read -r path; do
    [[ $(stat -c '%a' "$path") == 644 ]] || die "unexpected file mode: $path"
done < <(find "$bundle" -type f -print | sort)
while IFS= read -r path; do
    [[ $(stat -c '%a' "$path") == 755 ]] || die "unexpected directory mode: $path"
done < <(find "$bundle" -mindepth 1 -type d -print | sort)

printf 'verified %s bundle with %s packages\n' \
    "$(jq -r '.product' "$bundle/manifest.v2.json")" \
    "$(jq -r '.packages | length' "$bundle/manifest.v2.json")"
