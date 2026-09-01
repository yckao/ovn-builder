#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

(($# == 2)) || die "usage: validate-build-only-stage-metadata.sh METADATA_DIR OUTPUT_JSON"

metadata_dir=$1
output_json=$2
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$root"

: "${IMAGE_PREFIX:?IMAGE_PREFIX is required}"
: "${RELEASE_SHA:?RELEASE_SHA is required}"
: "${RELEASE_RUN_ID:?RELEASE_RUN_ID is required}"
: "${RELEASE_RUN_ATTEMPT:?RELEASE_RUN_ATTEMPT is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_REPOSITORY_OWNER:?GITHUB_REPOSITORY_OWNER is required}"

owner=$(tr '[:upper:]' '[:lower:]' <<< "$GITHUB_REPOSITORY_OWNER")
owner=${owner%$'\n'}
expected_prefix="ghcr.io/$owner/ovn-builder"
[[ $IMAGE_PREFIX == "$expected_prefix" ]] \
    || die "build-only publication prefix must be $expected_prefix"
[[ $RELEASE_SHA =~ ^[0-9a-f]{40}$ ]] || die "RELEASE_SHA is not a full commit SHA"
[[ $RELEASE_RUN_ID =~ ^[1-9][0-9]*$ ]] || die "RELEASE_RUN_ID is not a positive integer"
[[ $RELEASE_RUN_ATTEMPT =~ ^[1-9][0-9]*$ ]] \
    || die "RELEASE_RUN_ATTEMPT is not a positive integer"
[[ $GITHUB_REPOSITORY =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
    || die "invalid GitHub repository name"

command -v jq >/dev/null || die "jq is required"

jq -e '
  [.cells[].id] == ["ovs-u2204", "ovs-u2404", "ovn-u2204", "ovn-u2404"] and
  [.builders[].id] == ["u2204", "u2404"]
' .github/ci-matrix.json >/dev/null \
    || die "build-only staging supports only the locked v1 product and builder cells"

expected_names=$'builder-u2204.json\nbuilder-u2404.json\nproduct-ovn-u2204.json\nproduct-ovn-u2404.json\nproduct-ovs-u2204.json\nproduct-ovs-u2404.json'
shopt -s dotglob nullglob
metadata_files=("$metadata_dir"/*)
((${#metadata_files[@]} == 6)) || die "expected exactly six staging metadata files"
for file in "${metadata_files[@]}"; do
    [[ -f $file && ${file##*/} == *.json ]] \
        || die "staging metadata directory contains an unexpected entry: ${file##*/}"
done
actual_names=$(printf '%s\n' "${metadata_files[@]##*/}" | LC_ALL=C sort)
[[ $actual_names == "$expected_names" ]] \
    || die "staging metadata file set is missing, duplicated, or unexpected"

for file in "${metadata_files[@]}"; do
    base=${file##*/}
    case "$base" in
        product-*.json)
            category=product
            expected_cell=${base#product-}
            expected_cell=${expected_cell%.json}
            expected_count=3
            ;;
        builder-*.json)
            category=builder
            expected_cell=${base#builder-}
            expected_cell=${expected_cell%.json}
            expected_count=1
            ;;
        *) die "unexpected staging metadata filename: $base" ;;
    esac

    jq -e \
        --arg category "$category" \
        --arg cell "$expected_cell" \
        --arg prefix "$IMAGE_PREFIX" \
        --arg run_id "$RELEASE_RUN_ID" \
        --arg max_run_attempt "$RELEASE_RUN_ATTEMPT" \
        --arg sha "$RELEASE_SHA" \
        --arg repository "$GITHUB_REPOSITORY" \
        --argjson expected_count "$expected_count" '
          (keys | sort) ==
            ["category", "cell_id", "descriptors", "image_prefix", "kernel_validation", "release_run", "schema"] and
          .schema == "ovn-builder.build-only-stage.v1" and
          .kernel_validation == "unverified" and
          .category == $category and
          .cell_id == $cell and
          .image_prefix == $prefix and
          (.release_run | keys | sort) == ["attempt", "id", "repository", "sha"] and
          .release_run.id == $run_id and
          (.release_run.attempt | test("^[1-9][0-9]*$")) and
          (.release_run.attempt | tonumber) <= ($max_run_attempt | tonumber) and
          .release_run.sha == $sha and
          .release_run.repository == $repository and
          (.descriptors | type) == "array" and
          (.descriptors | length) == $expected_count and
          all(.descriptors[]; .cell_id == $cell)
        ' "$file" >/dev/null || die "invalid build-only staging metadata wrapper: $base"
done

stage_base="_staging-build-only-$RELEASE_RUN_ID"
expected=$(jq -cS \
    --arg prefix "$IMAGE_PREFIX" \
    --arg sha "$RELEASE_SHA" \
    --arg stage_base "$stage_base" '
      ([.cells[] as $cell |
        ({
          cell_id: $cell.id,
          kind: "carrier",
          source_ref: ($prefix + "/" + $cell.product + "-debs:" + $stage_base + "-" + $cell.id),
          canonical_ref: ($prefix + "/" + $cell.product + "-debs:" + $cell.release_tag + "-kernel-unverified-" + $sha)
        }, {
          cell_id: $cell.id,
          kind: "runtime",
          source_ref: ($prefix + "/" + $cell.product + ":" + $stage_base + "-" + $cell.id),
          canonical_ref: ($prefix + "/" + $cell.product + ":" + $cell.release_tag + "-kernel-unverified-" + $sha)
        }, {
          cell_id: $cell.id,
          kind: "oci-bundle",
          source_ref: ($prefix + "/" + $cell.product + "-debs-oci:" + $stage_base + "-" + $cell.id),
          canonical_ref: ($prefix + "/" + $cell.product + "-debs-oci:" + $cell.release_tag + "-kernel-unverified-" + $sha)
        })] +
       [.builders[] as $cell | {
          cell_id: $cell.id,
          kind: "builder",
          source_ref: ($prefix + "/builder:" + $stage_base + "-builder-" + $cell.id),
          canonical_ref: ($prefix + "/builder:" + $cell.release_tag + "-kernel-unverified-" + $sha)
       }]) | sort_by(.canonical_ref)
    ' .github/ci-matrix.json)

actual=$(jq -cSs '[.[].descriptors[]] | sort_by(.canonical_ref)' "${metadata_files[@]}")
jq -e \
    --arg sha "$RELEASE_SHA" '
      length == 14 and
      ([.[].canonical_ref] | unique | length) == 14 and
      ([.[].source_ref] | unique | length) == 14 and
      all(.[];
        (keys | sort) == ["canonical_ref", "cell_id", "digest", "kind", "source_ref"] and
        (.digest | test("^sha256:[0-9a-f]{64}$")) and
        (.source_ref | test("^ghcr\\.io/[a-z0-9._/-]+:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$")) and
        (.canonical_ref | endswith("-kernel-unverified-" + $sha)) and
        (.canonical_ref | test("^ghcr\\.io/[a-z0-9._/-]+:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$")))
    ' <<< "$actual" >/dev/null || die "invalid or duplicate build-only staged descriptors"

actual_contract=$(jq -cS '[.[] | del(.digest)]' <<< "$actual")
[[ $actual_contract == "$expected" ]] \
    || die "staging metadata does not match the locked build-only reference contract"

tmp_output=$(mktemp "${output_json##*/}.XXXXXX")
trap 'rm -f -- "$tmp_output"' EXIT
jq -nS \
    --arg prefix "$IMAGE_PREFIX" \
    --arg run_id "$RELEASE_RUN_ID" \
    --arg run_attempt "$RELEASE_RUN_ATTEMPT" \
    --arg sha "$RELEASE_SHA" \
    --arg repository "$GITHUB_REPOSITORY" \
    --argjson descriptors "$actual" '{
      schema: "ovn-builder.build-only-release-set.v1",
      kernel_validation: "unverified",
      image_prefix: $prefix,
      release_run: {
        id: $run_id,
        attempt: $run_attempt,
        sha: $sha,
        repository: $repository
      },
      descriptors: $descriptors
    }' > "$tmp_output"
mv -- "$tmp_output" "$output_json"
trap - EXIT

echo "validated 14 kernel-unverified staged descriptors and wrote $output_json"
