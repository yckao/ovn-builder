#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

if (($# != 2)); then
    echo "usage: push-bundle.sh OCI_REFERENCE BUNDLE_DIR" >&2
    exit 2
fi

reference=$1
bundle=$2
command -v oras >/dev/null || { echo "oras is required" >&2; exit 2; }
"$(dirname -- "$0")/../bundle/verify.sh" "$bundle"

declare -a annotations=()
if [[ -n ${OCI_SOURCE:-} ]]; then
    [[ $OCI_SOURCE =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || {
        echo "OCI_SOURCE must identify a GitHub repository" >&2
        exit 2
    }
    annotations+=(--annotation "org.opencontainers.image.source=$OCI_SOURCE")
fi
if [[ -n ${OCI_REVISION:-} ]]; then
    [[ $OCI_REVISION =~ ^[0-9a-f]{40}$ ]] || {
        echo "OCI_REVISION must be a full lowercase Git commit SHA" >&2
        exit 2
    }
    annotations+=(--annotation "org.opencontainers.image.revision=$OCI_REVISION")
fi
declare -a layers=()
while IFS= read -r -d '' path; do
    relative=${path#"$bundle"/}
    media_type=application/octet-stream
    case "$relative" in
        *.deb) media_type=application/vnd.debian.binary-package ;;
        *.json) media_type=application/json ;;
        SHA256SUMS|*.txt|*.changes|*.buildinfo) media_type=text/plain ;;
    esac
    layers+=("$relative:$media_type")
done < <(find "$bundle" -type f -print0 | sort -z)

product=$(jq -r '.product' "$bundle/manifest.v2.json")
ubuntu=$(jq -r '.target.ubuntu_version' "$bundle/manifest.v2.json")
source_date_epoch=$(jq -r '.build.source_date_epoch' "$bundle/manifest.v2.json")
[[ $source_date_epoch =~ ^[1-9][0-9]*$ ]] || {
    echo "bundle manifest has an invalid source_date_epoch" >&2
    exit 2
}
created=$(jq -nr --argjson epoch "$source_date_epoch" '$epoch | todateiso8601')
(
    cd "$bundle"
    oras push \
        --artifact-type application/vnd.ovn-builder.deb-bundle.v2 \
        --annotation "org.opencontainers.image.created=$created" \
        --annotation "io.ovn-builder.product=$product" \
        --annotation "io.ovn-builder.ubuntu=$ubuntu" \
        "${annotations[@]}" \
        "$reference" "${layers[@]}"
)
