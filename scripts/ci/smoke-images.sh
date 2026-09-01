#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
(($# == 6)) || die "usage: smoke-images.sh PRODUCT BUNDLE CARRIER_TAR RUNTIME_TAR CARRIER_IMAGE RUNTIME_IMAGE"

product=$1
bundle=$2
carrier_tar=$3
runtime_tar=$4
carrier_image=$5
runtime_image=$6
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

"$root/scripts/bundle/verify.sh" "$bundle"
docker load --input "$carrier_tar" >/dev/null
docker load --input "$runtime_tar" >/dev/null

[[ $(docker image inspect -f '{{.Config.WorkingDir}}' "$carrier_image") == /workdir ]] \
    || die "carrier WorkingDir is not /workdir"
[[ $(docker image inspect -f '{{.Config.User}}' "$carrier_image") == 65534:65534 ]] \
    || die "carrier does not use the unprivileged user"
[[ $(docker image inspect -f '{{index .Config.Labels "io.ovn-builder.bundle.profile"}}' "$carrier_image") == generated-only ]] \
    || die "carrier profile label is wrong"
expected_kernel=$(jq -r '.target.expected_kernel' "$bundle/manifest.v1.json")
[[ $expected_kernel =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-generic$ ]] \
    || die "bundle expected kernel is invalid"
for image in "$carrier_image" "$runtime_image"; do
    [[ $(docker image inspect -f '{{index .Config.Labels "io.ovn-builder.target-kernel"}}' "$image") == "$expected_kernel" ]] \
        || die "image target-kernel label is wrong: $image"
    docker image inspect "$image" \
        | jq -e '((.[0].Config.Labels // {}) | has("io.ovn-builder.tested-kernel") | not)' >/dev/null \
        || die "image must not claim a tested kernel: $image"
done
if [[ -n ${REPOSITORY_SOURCE:-} ]]; then
    [[ $(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.source"}}' "$carrier_image") == "$REPOSITORY_SOURCE" ]] \
        || die "carrier source label is wrong"
    [[ $(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.source"}}' "$runtime_image") == "$REPOSITORY_SOURCE" ]] \
        || die "runtime source label is wrong"
fi
if [[ -n ${REPOSITORY_REVISION:-} ]]; then
    for image in "$carrier_image" "$runtime_image"; do
        [[ $(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$image") == "$REPOSITORY_REVISION" ]] \
            || die "image repository revision label is wrong: $image"
    done
fi
[[ $(docker image inspect -f '{{json .Config.Volumes}}' "$carrier_image") == null ]] \
    || die "carrier must not declare a volume over /workdir"

docker run --rm --pull=never --network=none --read-only --cap-drop=ALL \
    --security-opt=no-new-privileges "$carrier_image" >/dev/null

tmp=$(mktemp -d)
cid=
cleanup() {
    [[ -z $cid ]] || docker rm -f "$cid" >/dev/null 2>&1 || true
    rm -rf -- "$tmp"
}
trap cleanup EXIT
cid=$(docker create --pull=never --network=none "$carrier_image")
docker cp "$cid:/workdir/." "$tmp/"
docker rm "$cid" >/dev/null
cid=
"$root/scripts/bundle/verify.sh" "$tmp" >/dev/null
cmp "$bundle/SHA256SUMS" "$tmp/SHA256SUMS"

version_output=$(docker run --rm --pull=never --network=none "$runtime_image")
case "$product" in
    ovs) grep -F "Open vSwitch 3.7.1" <<< "$version_output" >/dev/null ;;
    ovn) grep -F "ovn-controller 26.03.2" <<< "$version_output" >/dev/null ;;
    *) die "unsupported product: $product" ;;
esac

echo "carrier and runtime image smoke tests passed for $product"
