#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

(($# == 1)) || die "usage: promote-release.sh RELEASE_SET_JSON"
release_set=$1

: "${GITHUB_REPOSITORY_OWNER:?GITHUB_REPOSITORY_OWNER is required}"
[[ -f $release_set ]] || die "release set does not exist: $release_set"
command -v jq >/dev/null || die "jq is required"
command -v oras >/dev/null || die "oras is required"

owner=$(tr '[:upper:]' '[:lower:]' <<< "$GITHUB_REPOSITORY_OWNER")
owner=${owner%$'\n'}
expected_prefix="ghcr.io/$owner/ovn-builder"

jq -e --arg prefix "$expected_prefix" '
  . as $root |
  (keys | sort) == ["descriptors", "image_prefix", "release_run", "schema"] and
  .schema == "ovn-builder.release-set.v1" and
  .image_prefix == $prefix and
  (.release_run | keys | sort) == ["attempt", "id", "repository", "sha"] and
  (.release_run.sha | test("^[0-9a-f]{40}$")) and
  (.descriptors | type) == "array" and
  (.descriptors | length) == 14 and
  ([.descriptors[].canonical_ref] | unique | length) == 14 and
  ([.descriptors[].source_ref] | unique | length) == 14 and
  all(.descriptors[];
    (keys | sort) == ["canonical_ref", "cell_id", "digest", "kind", "source_ref"] and
    (.digest | test("^sha256:[0-9a-f]{64}$")) and
    (.source_ref | startswith($prefix + "/")) and
    (.canonical_ref | startswith($prefix + "/")) and
    (.canonical_ref | endswith("-" + $root.release_run.sha)) and
    ((.canonical_ref | contains("-kernel-unverified-")) | not) and
    (.source_ref | test("^ghcr\\.io/[a-z0-9._/-]+:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$")) and
    (.canonical_ref | test("^ghcr\\.io/[a-z0-9._/-]+:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$")))
' "$release_set" >/dev/null || die "invalid release set"

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
plan=$tmp/promotion-plan.tsv
: > "$plan"

# This entire loop is read-only. No canonical tag is written until every staged
# digest and every existing canonical tag has passed the preflight.
while IFS=$'\t' read -r source_ref canonical_ref expected_digest; do
    source_repository=${source_ref%:*}
    canonical_repository=${canonical_ref%:*}
    canonical_tag=${canonical_ref##*:}
    [[ $source_repository == "$canonical_repository" ]] \
        || die "staging and canonical references are in different repositories: $canonical_ref"

    staged_digest=$(oras resolve "$source_ref") \
        || die "cannot resolve staged reference: $source_ref"
    [[ $staged_digest == "$expected_digest" ]] \
        || die "staged digest changed for $source_ref: expected $expected_digest, got $staged_digest"

    tags_file=$tmp/$(printf '%s' "$canonical_repository" | sha256sum | cut -d' ' -f1).tags.json
    if [[ ! -f $tags_file ]]; then
        oras repo tags "$canonical_repository" --format json > "$tags_file" \
            || die "cannot enumerate tags for $canonical_repository"
        jq -e '(.tags | type) == "array"' "$tags_file" >/dev/null \
            || die "registry returned an invalid tag list for $canonical_repository"
    fi

    if jq -e --arg tag "$canonical_tag" '.tags | index($tag) != null' "$tags_file" >/dev/null; then
        canonical_digest=$(oras resolve "$canonical_ref") \
            || die "cannot resolve existing canonical tag: $canonical_ref"
        [[ $canonical_digest == "$expected_digest" ]] \
            || die "refusing to replace $canonical_ref: expected $expected_digest, found $canonical_digest"
        state=present
    else
        state=create
    fi

    printf '%s\t%s\t%s\t%s\n' \
        "$state" "$canonical_repository" "$canonical_tag" "$expected_digest" >> "$plan"
done < <(jq -r '.descriptors[] | [.source_ref, .canonical_ref, .digest] | @tsv' "$release_set")

[[ $(wc -l < "$plan") -eq 14 ]] || die "promotion plan does not contain 14 descriptors"
echo "all staged digests and canonical tags passed preflight"

# OCI Distribution has no multi-repository transaction. These operations are
# deliberately idempotent: a retry accepts an already-present identical digest
# and fills in only tags that were still absent.
while IFS=$'\t' read -r state repository tag expected_digest; do
    canonical_ref="$repository:$tag"
    if [[ $state == create ]]; then
        fresh_tags=$tmp/fresh-$(printf '%s' "$canonical_ref" | sha256sum | cut -d' ' -f1).json
        oras repo tags "$repository" --format json > "$fresh_tags" \
            || die "cannot refresh tags for $repository"
        jq -e '(.tags | type) == "array"' "$fresh_tags" >/dev/null \
            || die "registry returned an invalid refreshed tag list for $repository"

        if jq -e --arg tag "$tag" '.tags | index($tag) != null' "$fresh_tags" >/dev/null; then
            raced_digest=$(oras resolve "$canonical_ref") \
                || die "cannot resolve canonical tag created after preflight: $canonical_ref"
            [[ $raced_digest == "$expected_digest" ]] \
                || die "refusing to replace $canonical_ref: it changed after preflight to $raced_digest"
            echo "kept concurrently-created identical tag $canonical_ref -> $expected_digest"
        else
            oras tag "$repository@$expected_digest" "$tag"
            echo "promoted $canonical_ref -> $expected_digest"
        fi
    else
        echo "kept identical canonical tag $canonical_ref -> $expected_digest"
    fi

    actual_digest=$(oras resolve "$canonical_ref") \
        || die "cannot resolve promoted canonical tag: $canonical_ref"
    [[ $actual_digest == "$expected_digest" ]] \
        || die "canonical verification failed for $canonical_ref"
done < "$plan"

# Verify the complete set once more before the workflow can report success.
while IFS=$'\t' read -r _state repository tag expected_digest; do
    canonical_ref="$repository:$tag"
    actual_digest=$(oras resolve "$canonical_ref") \
        || die "final canonical resolution failed for $canonical_ref"
    [[ $actual_digest == "$expected_digest" ]] \
        || die "final canonical digest mismatch for $canonical_ref"
done < "$plan"

echo "verified all 14 canonical full-SHA tags"
