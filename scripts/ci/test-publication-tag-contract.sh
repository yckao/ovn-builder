#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$root"

command -v jq >/dev/null || die "jq is required"
command -v sha256sum >/dev/null || die "sha256sum is required"

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

export IMAGE_PREFIX=ghcr.io/testowner/ovn-builder
export RELEASE_SHA=0123456789abcdef0123456789abcdef01234567
export RELEASE_RUN_ID=424242
export RELEASE_RUN_ATTEMPT=3
export GITHUB_REPOSITORY=TestOwner/ovn-builder
export GITHUB_REPOSITORY_OWNER=TestOwner

fixture_digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
old_digest=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
conflict_digest=sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
race_digest=sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd

write_product_metadata() {
    local schema=$1 validation=$2 stage_base=$3 cell_id=$4 output=$5
    jq -nS \
        --slurpfile matrix .github/ci-matrix.json \
        --arg schema "$schema" \
        --arg validation "$validation" \
        --arg prefix "$IMAGE_PREFIX" \
        --arg run_id "$RELEASE_RUN_ID" \
        --arg attempt "$RELEASE_RUN_ATTEMPT" \
        --arg sha "$RELEASE_SHA" \
        --arg repository "$GITHUB_REPOSITORY" \
        --arg stage_base "$stage_base" \
        --arg cell_id "$cell_id" \
        --arg digest "$fixture_digest" '
          ($matrix[0].cells[] | select(.id == $cell_id)) as $cell |
          def publication_tags: [
            {tag: $cell.release_tag, policy: "immutable"},
            {tag: $cell.alias_tag, policy: "moving"}
          ];
          def descriptor($kind; $suffix):
            ($prefix + "/" + $cell.product + $suffix) as $image |
            {
              cell_id: $cell.id,
              kind: $kind,
              source_ref: ($image + ":" + $stage_base + "-" + $cell.id),
              digest: $digest,
              canonical_refs: (
                [publication_tags[] | {policy, ref: ($image + ":" + .tag)}]
                | sort_by(.ref)
              )
            };
          {
            schema: $schema,
            kernel_validation: $validation,
            category: "product",
            cell_id: $cell.id,
            image_prefix: $prefix,
            release_run: {
              id: $run_id,
              attempt: $attempt,
              sha: $sha,
              repository: $repository
            },
            descriptors: [
              descriptor("carrier"; "-debs"),
              descriptor("runtime"; ""),
              descriptor("oci-bundle"; "-debs-oci")
            ]
          }
        ' > "$output"
}

write_builder_metadata() {
    local schema=$1 validation=$2 stage_base=$3 cell_id=$4 output=$5
    jq -nS \
        --slurpfile matrix .github/ci-matrix.json \
        --arg schema "$schema" \
        --arg validation "$validation" \
        --arg prefix "$IMAGE_PREFIX" \
        --arg run_id "$RELEASE_RUN_ID" \
        --arg attempt "$RELEASE_RUN_ATTEMPT" \
        --arg sha "$RELEASE_SHA" \
        --arg repository "$GITHUB_REPOSITORY" \
        --arg stage_base "$stage_base" \
        --arg cell_id "$cell_id" \
        --arg digest "$fixture_digest" '
          ($matrix[0].builders[] | select(.id == $cell_id)) as $cell |
          ($prefix + "/builder") as $image |
          def publication_tags: [
            {tag: $cell.release_tag, policy: "immutable"},
            {tag: $cell.alias_tag, policy: "moving"}
          ];
          {
            schema: $schema,
            kernel_validation: $validation,
            category: "builder",
            cell_id: $cell.id,
            image_prefix: $prefix,
            release_run: {
              id: $run_id,
              attempt: $attempt,
              sha: $sha,
              repository: $repository
            },
            descriptors: [{
              cell_id: $cell.id,
              kind: "builder",
              source_ref: ($image + ":" + $stage_base + "-builder-" + $cell.id),
              digest: $digest,
              canonical_refs: (
                [publication_tags[] | {policy, ref: ($image + ":" + .tag)}]
                | sort_by(.ref)
              )
            }]
          }
        ' > "$output"
}

make_stage_metadata() {
    local mode=$1 destination=$2 schema validation stage_base
    mkdir -p "$destination"
    case "$mode" in
        build-only)
            schema=ovn-builder.build-only-stage.v2
            validation=unverified
            stage_base=_staging-build-only-$RELEASE_RUN_ID
            ;;
        verified)
            schema=ovn-builder.release-stage.v2
            validation=verified
            stage_base=_staging-$RELEASE_RUN_ID
            ;;
        *) die "unknown fixture mode: $mode" ;;
    esac

    while IFS=$'\t' read -r cell_id; do
        write_product_metadata \
            "$schema" "$validation" "$stage_base" "$cell_id" \
            "$destination/product-$cell_id.json"
    done < <(jq -r '.cells[].id' .github/ci-matrix.json)

    while IFS=$'\t' read -r cell_id; do
        write_builder_metadata \
            "$schema" "$validation" "$stage_base" "$cell_id" \
            "$destination/builder-$cell_id.json"
    done < <(jq -r '.builders[].id' .github/ci-matrix.json)
}

failure_index=0
expect_failure() {
    local description=$1 expected_message=$2
    shift 2
    failure_index=$((failure_index + 1))
    local log=$tmp/expected-failure-$failure_index.log
    if "$@" > "$log" 2>&1; then
        die "$description unexpectedly succeeded"
    fi
    if ! grep -F "$expected_message" "$log" >/dev/null; then
        sed -n '1,120p' "$log" >&2
        die "$description failed for the wrong reason"
    fi
}

validate_fixture_mode() {
    local mode=$1 validator release_schema validation mutation_index
    case "$mode" in
        build-only)
            validator=$root/scripts/release/validate-build-only-stage-metadata.sh
            release_schema=ovn-builder.build-only-release-set.v2
            validation=unverified
            mutation_index=0
            ;;
        verified)
            validator=$root/scripts/release/validate-stage-metadata.sh
            release_schema=ovn-builder.release-set.v2
            validation=verified
            mutation_index=1
            ;;
        *) die "unknown validation mode: $mode" ;;
    esac

    local stage=$tmp/stage-$mode
    local release_set=$tmp/release-set-$mode.json
    make_stage_metadata "$mode" "$stage"
    "$validator" "$stage" "$release_set" > "$tmp/validation-$mode.log"

    jq -e \
        --arg schema "$release_schema" \
        --arg validation "$validation" \
        --arg sha "$RELEASE_SHA" '
          .schema == $schema and
          .kernel_validation == $validation and
          (.descriptors | length) == 14 and
          ([.descriptors[].source_ref] | unique | length) == 14 and
          ([.descriptors[].canonical_refs[].ref] | length) == 28 and
          ([.descriptors[].canonical_refs[].ref] | unique | length) == 28 and
          ([.descriptors[].canonical_refs[] | select(.policy == "immutable")] | length) == 14 and
          ([.descriptors[].canonical_refs[] | select(.policy == "moving")] | length) == 14 and
          all(.descriptors[].canonical_refs[].ref;
            (contains("kernel-unverified") | not) and
            (endswith($sha) | not))
        ' "$release_set" >/dev/null \
        || die "$mode validator emitted an invalid 14-descriptor/28-reference release set"

    local mutated=$tmp/stage-$mode-mutated
    cp -R "$stage" "$mutated"
    local metadata=$mutated/product-ovs-u2404.json
    local next=$tmp/mutated-$mode.json
    jq --arg sha "$RELEASE_SHA" --argjson index "$mutation_index" '
      .descriptors[0].canonical_refs[$index].ref += ("-kernel-unverified-" + $sha)
    ' "$metadata" > "$next"
    mv -- "$next" "$metadata"
    expect_failure \
        "$mode validator mutated-reference check" \
        "staging metadata does not match the locked publication reference contract" \
        "$validator" "$mutated" "$tmp/rejected-$mode.json"
}

validate_fixture_mode build-only
validate_fixture_mode verified

fake_bin=$tmp/fake-bin
mkdir -p "$fake_bin"
ln -s "$root/scripts/ci/fixtures/publication-tag-contract/fake-oras" "$fake_bin/oras"
export PATH=$fake_bin:$PATH
export FAKE_ORAS_STATE=$tmp/fake-registry.json
export FAKE_ORAS_LOG=$tmp/fake-oras-writes.tsv

seed_staged_refs() {
    local release_set=$1 next=$tmp/registry-next.json
    jq -nS --slurpfile release "$release_set" '
      $release[0] as $set |
      {
        refs: (reduce $set.descriptors[] as $descriptor
          ({}; .[$descriptor.source_ref] = $descriptor.digest)),
        resolve_counts: {}
      }
    ' > "$next"
    mv -- "$next" "$FAKE_ORAS_STATE"
    : > "$FAKE_ORAS_LOG"
    unset FAKE_ORAS_RACE_REF FAKE_ORAS_RACE_DIGEST FAKE_ORAS_RACE_ON_RESOLVE || true
}

seed_public_refs() {
    local release_set=$1 moving_digest=${2:-} next=$tmp/registry-next.json
    jq -S \
        --slurpfile release "$release_set" \
        --arg moving_digest "$moving_digest" '
      . as $registry |
      reduce (
        $release[0].descriptors[] as $descriptor |
        $descriptor.canonical_refs[] |
        {ref: .ref, policy: .policy, digest: $descriptor.digest}
      ) as $entry ($registry;
        .refs[$entry.ref] = (
          if $entry.policy == "moving" and $moving_digest != ""
          then $moving_digest
          else $entry.digest
          end
        )) |
      .resolve_counts = {}
    ' "$FAKE_ORAS_STATE" > "$next"
    mv -- "$next" "$FAKE_ORAS_STATE"
}

set_registry_ref() {
    local ref=$1 digest=$2 next=$tmp/registry-next.json
    jq --arg ref "$ref" --arg digest "$digest" \
        '.refs[$ref] = $digest | .resolve_counts = {}' \
        "$FAKE_ORAS_STATE" > "$next"
    mv -- "$next" "$FAKE_ORAS_STATE"
}

assert_public_refs_match() {
    local release_set=$1
    jq -en \
        --slurpfile registry "$FAKE_ORAS_STATE" \
        --slurpfile release "$release_set" '
      $registry[0] as $state |
      $release[0] as $set |
      all($set.descriptors[];
        . as $descriptor |
        all(.canonical_refs[]; $state.refs[.ref] == $descriptor.digest))
    ' >/dev/null || die "fake registry public references do not match the release set"
}

build_only_release=$tmp/release-set-build-only.json
verified_release=$tmp/release-set-verified.json

# An existing immutable tag at another digest must abort during the read-only
# preflight, before any public write can occur.
seed_staged_refs "$build_only_release"
immutable_ref=$(jq -r '[.descriptors[].canonical_refs[] | select(.policy == "immutable")][0].ref' \
    "$build_only_release")
set_registry_ref "$immutable_ref" "$conflict_digest"
expect_failure \
    "immutable conflict preflight" \
    "refusing to replace immutable tag" \
    "$root/scripts/release/promote-build-only.sh" "$build_only_release"
[[ ! -s $FAKE_ORAS_LOG ]] || die "immutable conflict wrote a public tag"

# Immutable identities already point at the expected digest; all moving aliases
# point at an older release and must be advanced exactly once.
seed_staged_refs "$build_only_release"
seed_public_refs "$build_only_release" "$old_digest"
"$root/scripts/release/promote-build-only.sh" "$build_only_release" \
    > "$tmp/promotion-moving.log"
[[ $(wc -l < "$FAKE_ORAS_LOG") -eq 14 ]] \
    || die "moving-alias promotion did not perform exactly 14 writes"
expected_moving=$(jq -r '.descriptors[].canonical_refs[] | select(.policy == "moving") | .ref' \
    "$build_only_release" | LC_ALL=C sort)
actual_writes=$(cut -f1 "$FAKE_ORAS_LOG" | LC_ALL=C sort)
[[ $actual_writes == "$expected_moving" ]] \
    || die "promotion wrote something other than the 14 moving aliases"
assert_public_refs_match "$build_only_release"

# A complete rerun is idempotent: it verifies every ref and performs no write.
"$root/scripts/release/promote-build-only.sh" "$build_only_release" \
    > "$tmp/promotion-idempotent.log"
[[ $(wc -l < "$FAKE_ORAS_LOG") -eq 14 ]] \
    || die "idempotent promotion rerun performed an additional write"
assert_public_refs_match "$build_only_release"

# Change one moving alias between preflight and the write phase. The verified
# promotion path must detect the compare-before-update race and refuse to write.
seed_staged_refs "$verified_release"
seed_public_refs "$verified_release"
race_ref=$(jq -r '[.descriptors[].canonical_refs[] | select(.policy == "moving")][0].ref' \
    "$verified_release")
set_registry_ref "$race_ref" "$old_digest"
export FAKE_ORAS_RACE_REF=$race_ref
export FAKE_ORAS_RACE_DIGEST=$race_digest
export FAKE_ORAS_RACE_ON_RESOLVE=2
expect_failure \
    "moving-alias race check" \
    "moving alias changed after preflight" \
    "$root/scripts/release/promote-release.sh" "$verified_release"
[[ ! -s $FAKE_ORAS_LOG ]] || die "raced promotion wrote a public tag"
[[ $(jq -r --arg ref "$race_ref" '.refs[$ref]' "$FAKE_ORAS_STATE") == "$race_digest" ]] \
    || die "fake registry did not inject the requested race"

echo "publication tag contract tests passed for both validator and promotion modes"
