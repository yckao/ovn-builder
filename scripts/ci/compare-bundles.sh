#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

if (($# != 2)); then
    echo "usage: compare-bundles.sh BUNDLE_A BUNDLE_B" >&2
    exit 2
fi

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
"$root/scripts/bundle/verify.sh" "$1"
"$root/scripts/bundle/verify.sh" "$2"
diff -ruN --no-dereference "$1" "$2"
echo "bundle payloads are byte-for-byte reproducible"
