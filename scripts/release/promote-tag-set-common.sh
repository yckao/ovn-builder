#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

(($# == 2)) || die "usage: promote-tag-set-common.sh MODE RELEASE_SET_JSON"
mode=$1
release_set=$2
case "$mode" in
    build-only)
        expected_schema=ovn-builder.build-only-release-set.v2
        expected_validation=unverified
        stage_prefix=_staging-build-only-
        ;;
    verified)
        expected_schema=ovn-builder.release-set.v2
        expected_validation=verified
        stage_prefix=_staging-
        ;;
    *) die "MODE must be build-only or verified" ;;
esac

: "${GITHUB_REPOSITORY_OWNER:?GITHUB_REPOSITORY_OWNER is required}"
[[ -f $release_set ]] || die "release set does not exist: $release_set"
command -v jq >/dev/null || die "jq is required"
command -v oras >/dev/null || die "oras is required"

owner=$(tr '[:upper:]' '[:lower:]' <<< "$GITHUB_REPOSITORY_OWNER")
owner=${owner%$'\n'}
expected_prefix="ghcr.io/$owner/ovn-builder"

jq -e \
  --arg prefix "$expected_prefix" \
  --arg schema "$expected_schema" \
  --arg validation "$expected_validation" \
  --arg stage_prefix "$stage_prefix" '
  . as $root |
  (keys | sort) == ["descriptors", "image_prefix", "kernel_validation", "release_run", "schema"] and
  .schema == $schema and
  .kernel_validation == $validation and
  .image_prefix == $prefix and
  (.release_run | keys | sort) == ["attempt", "id", "repository", "sha"] and
  (.release_run.id | test("^[1-9][0-9]*$")) and
  (.release_run.attempt | test("^[1-9][0-9]*$")) and
  (.release_run.sha | test("^[0-9a-f]{40}$")) and
  (.release_run.repository | test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")) and
  (.descriptors | type) == "array" and
  (.descriptors | length) == 14 and
  ([.descriptors[].source_ref] | unique | length) == 14 and
  ([.descriptors[].canonical_refs[].ref] | length) == 28 and
  ([.descriptors[].canonical_refs[].ref] | unique | length) == 28 and
  ([.descriptors[].canonical_refs[] | select(.policy == "immutable")] | length) == 14 and
  ([.descriptors[].canonical_refs[] | select(.policy == "moving")] | length) == 14 and
  ([.descriptors[] | select(.kind == "carrier")] | length) == 4 and
  ([.descriptors[] | select(.kind == "runtime")] | length) == 4 and
  ([.descriptors[] | select(.kind == "oci-bundle")] | length) == 4 and
  ([.descriptors[] | select(.kind == "builder")] | length) == 2 and
  all(.descriptors[];
    (keys | sort) == ["canonical_refs", "cell_id", "digest", "kind", "source_ref"] and
    (.digest | test("^sha256:[0-9a-f]{64}$")) and
    (.source_ref | startswith($prefix + "/")) and
    (.source_ref | contains(":" + $stage_prefix + $root.release_run.id + "-")) and
    (.source_ref | test("^ghcr\\.io/[a-z0-9._/-]+:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$")) and
    (.canonical_refs | length) == 2 and
    (.canonical_refs == (.canonical_refs | sort_by(.ref))) and
    ([.canonical_refs[].policy] | sort) == ["immutable", "moving"] and
    all(.canonical_refs[];
      (keys | sort) == ["policy", "ref"] and
      (.ref | startswith($prefix + "/")) and
      ((.ref | contains("kernel-unverified")) | not) and
      ((.ref | endswith($root.release_run.sha)) | not) and
      (.ref | test("^ghcr\\.io/[a-z0-9._/-]+:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$"))))
' "$release_set" >/dev/null || die "invalid publication release set"

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
plan=$tmp/promotion-plan.tsv
: > "$plan"

# Resolve each staged artifact once before looking at any public tag.
while IFS=$'\t' read -r source_ref expected_digest; do
    staged_digest=$(oras resolve "$source_ref") \
        || die "cannot resolve staged reference: $source_ref"
    [[ $staged_digest == "$expected_digest" ]] \
        || die "staged digest changed for $source_ref: expected $expected_digest, got $staged_digest"
done < <(jq -r '.descriptors[] | [.source_ref, .digest] | @tsv' "$release_set")

# This loop is read-only. Immutable conflicts and the current value of every
# moving alias are known before the first public tag is written.
while IFS=$'\t' read -r source_ref canonical_ref policy expected_digest; do
    source_repository=${source_ref%:*}
    canonical_repository=${canonical_ref%:*}
    canonical_tag=${canonical_ref##*:}
    [[ $source_repository == "$canonical_repository" ]] \
        || die "staging and public references are in different repositories: $canonical_ref"

    tags_file=$tmp/$(printf '%s' "$canonical_repository" | sha256sum | cut -d' ' -f1).tags.json
    if [[ ! -f $tags_file ]]; then
        oras repo tags "$canonical_repository" --format json > "$tags_file" \
            || die "cannot enumerate tags for $canonical_repository"
        jq -e '(.tags | type) == "array"' "$tags_file" >/dev/null \
            || die "registry returned an invalid tag list for $canonical_repository"
    fi

    previous=-
    if jq -e --arg tag "$canonical_tag" '.tags | index($tag) != null' "$tags_file" >/dev/null; then
        previous=$(oras resolve "$canonical_ref") \
            || die "cannot resolve existing public tag: $canonical_ref"
        if [[ $previous == "$expected_digest" ]]; then
            state=present
        elif [[ $policy == immutable ]]; then
            die "refusing to replace immutable tag $canonical_ref: expected $expected_digest, found $previous"
        else
            state=update
        fi
    else
        state=create
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$policy" "$state" "$canonical_repository" "$canonical_tag" "$expected_digest" "$previous" >> "$plan"
done < <(jq -r '
  .descriptors[] as $descriptor |
  $descriptor.canonical_refs[] |
  [$descriptor.source_ref, .ref, .policy, $descriptor.digest] | @tsv
' "$release_set")

[[ $(wc -l < "$plan") -eq 28 ]] || die "promotion plan does not contain 28 tags"
echo "all 14 staged digests and 28 public tags passed preflight"

promote_policy() {
    local phase=$1 policy state repository tag expected_digest previous
    while IFS=$'\t' read -r policy state repository tag expected_digest previous; do
        [[ $policy == "$phase" ]] || continue
        canonical_ref="$repository:$tag"

        case "$state" in
            create)
                fresh_tags=$tmp/fresh-$(printf '%s' "$canonical_ref" | sha256sum | cut -d' ' -f1).json
                oras repo tags "$repository" --format json > "$fresh_tags" \
                    || die "cannot refresh tags for $repository"
                jq -e '(.tags | type) == "array"' "$fresh_tags" >/dev/null \
                    || die "registry returned an invalid refreshed tag list for $repository"
                if jq -e --arg tag "$tag" '.tags | index($tag) != null' "$fresh_tags" >/dev/null; then
                    raced_digest=$(oras resolve "$canonical_ref") \
                        || die "cannot resolve public tag created after preflight: $canonical_ref"
                    [[ $raced_digest == "$expected_digest" ]] \
                        || die "refusing to replace $canonical_ref: it appeared after preflight at $raced_digest"
                    echo "kept concurrently-created identical tag $canonical_ref -> $expected_digest"
                else
                    oras tag "$repository@$expected_digest" "$tag"
                    echo "created $canonical_ref -> $expected_digest"
                fi
                ;;
            present)
                current=$(oras resolve "$canonical_ref") \
                    || die "cannot re-resolve public tag: $canonical_ref"
                [[ $current == "$expected_digest" ]] \
                    || die "public tag changed after preflight: $canonical_ref is now $current"
                echo "kept identical tag $canonical_ref -> $expected_digest"
                ;;
            update)
                [[ $policy == moving ]] || die "only a moving alias may be updated"
                current=$(oras resolve "$canonical_ref") \
                    || die "cannot re-resolve moving alias: $canonical_ref"
                if [[ $current == "$expected_digest" ]]; then
                    echo "kept concurrently-updated alias $canonical_ref -> $expected_digest"
                else
                    [[ $current == "$previous" ]] \
                        || die "moving alias changed after preflight: $canonical_ref is now $current"
                    oras tag "$repository@$expected_digest" "$tag"
                    echo "updated moving alias $canonical_ref: $previous -> $expected_digest"
                fi
                ;;
            *) die "invalid promotion state: $state" ;;
        esac

        actual_digest=$(oras resolve "$canonical_ref") \
            || die "cannot resolve promoted tag: $canonical_ref"
        [[ $actual_digest == "$expected_digest" ]] \
            || die "tag verification failed for $canonical_ref"
    done < "$plan"
}

# Write every immutable release identity before changing any moving alias.
promote_policy immutable
promote_policy moving

while IFS=$'\t' read -r _policy _state repository tag expected_digest _previous; do
    canonical_ref="$repository:$tag"
    actual_digest=$(oras resolve "$canonical_ref") \
        || die "final tag resolution failed for $canonical_ref"
    [[ $actual_digest == "$expected_digest" ]] \
        || die "final tag digest mismatch for $canonical_ref"
done < "$plan"

echo "verified all 14 artifacts and 28 public tags"
