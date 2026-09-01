#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
(($# == 2)) || die "usage: extract-image.sh IMAGE NEW_DESTINATION"

image=$1
requested=$2
[[ -n $image && -n $requested ]] || die "arguments must not be empty"
[[ ! -e $requested ]] || die "destination already exists: $requested"

parent=$(dirname -- "$requested")
base=$(basename -- "$requested")
[[ $base != . && $base != .. && -n $base ]] || die "unsafe destination"
mkdir -p -- "$parent"
parent=$(cd -P -- "$parent" && pwd)
dest=$parent/$base
[[ ! -e $dest ]] || die "destination appeared concurrently"

tmp=$(mktemp -d "$parent/.${base}.tmp.XXXXXX")
cid=
cleanup() {
    if [[ -n $cid ]]; then docker rm -f "$cid" >/dev/null 2>&1 || true; fi
    if [[ -n ${tmp:-} && -d $tmp ]]; then rm -rf -- "$tmp"; fi
}
trap cleanup EXIT HUP INT TERM

docker image inspect "$image" >/dev/null || die "image is not loaded"
payload_path=$(docker image inspect -f '{{index .Config.Labels "io.ovn-builder.payload.path"}}' "$image")
profile=$(docker image inspect -f '{{index .Config.Labels "io.ovn-builder.bundle.profile"}}' "$image")
[[ $payload_path == /workdir ]] || die "unexpected payload path label"
[[ $profile == generated-only ]] || die "unexpected bundle profile"

docker run --rm --pull=never --network=none --read-only --cap-drop=ALL \
    --security-opt=no-new-privileges "$image"

cid=$(docker create --pull=never --network=none "$image")
docker cp "$cid:/workdir/." "$tmp/"
docker rm "$cid" >/dev/null
cid=

"$(dirname -- "$0")/verify.sh" "$tmp"
mv -- "$tmp" "$dest"
tmp=
printf 'verified bundle extracted to %s\n' "$dest"
