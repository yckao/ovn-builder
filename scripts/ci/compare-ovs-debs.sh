#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
export LC_ALL=C TZ=UTC

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

(($# == 2)) || die "usage: compare-ovs-debs.sh OVS_BUNDLE OVN_BUNDLE"

ovs_bundle=$1
ovn_bundle=$2
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

"$root/scripts/bundle/verify.sh" "$ovs_bundle" >/dev/null
"$root/scripts/bundle/verify.sh" "$ovn_bundle" >/dev/null

ovs_manifest=$ovs_bundle/manifest.v1.json
ovn_manifest=$ovn_bundle/manifest.v1.json

[[ $(jq -r '.product' "$ovs_manifest") == ovs ]] || die "first bundle is not an OVS bundle"
[[ $(jq -r '.product' "$ovn_manifest") == ovn ]] || die "second bundle is not an OVN bundle"
jq -e 'all(.packages[]; .component == "ovs")' "$ovs_manifest" >/dev/null \
    || die "standalone OVS bundle contains a non-OVS package"
jq -e 'any(.packages[]; .component == "ovn")' "$ovn_manifest" >/dev/null \
    || die "OVN bundle contains no OVN packages"

ovs_target=$(jq -S -c '.target | {ubuntu_version,architecture}' "$ovs_manifest")
ovn_target=$(jq -S -c '.target | {ubuntu_version,architecture}' "$ovn_manifest")
[[ $ovs_target == "$ovn_target" ]] || die "bundle Ubuntu/architecture targets differ"

ovs_source=$(jq -S -c '.source.ovs' "$ovs_manifest")
ovn_source=$(jq -S -c '.source.ovs' "$ovn_manifest")
[[ $ovs_source == "$ovn_source" ]] || die "bundle OVS source identities differ"

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

jq -S -c '[.packages[] | select(.component == "ovs")]' \
    "$ovs_manifest" > "$tmp/ovs-packages.json"
jq -S -c '[.packages[] | select(.component == "ovs")]' \
    "$ovn_manifest" > "$tmp/ovn-packages.json"
cmp -s "$tmp/ovs-packages.json" "$tmp/ovn-packages.json" \
    || die "OVS package manifests differ between standalone and OVN bundles"

jq -r '.packages[] | select(.component == "ovs") | .file' \
    "$ovs_manifest" > "$tmp/files"
[[ -s $tmp/files ]] || die "OVS package set is empty"

while IFS= read -r file; do
    [[ $file =~ ^[A-Za-z0-9][A-Za-z0-9.+_~:-]*\.deb$ ]] \
        || die "unsafe OVS package filename: $file"
    [[ -f $ovs_bundle/$file && ! -L $ovs_bundle/$file ]] \
        || die "standalone OVS package is missing: $file"
    [[ -f $ovn_bundle/$file && ! -L $ovn_bundle/$file ]] \
        || die "OVN bundle OVS package is missing: $file"
    cmp -s "$ovs_bundle/$file" "$ovn_bundle/$file" \
        || die "OVS package bytes differ: $file"
done < "$tmp/files"

echo "standalone and OVN bundles contain byte-identical OVS DEBs"
