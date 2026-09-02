#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

(($# == 2)) || die "usage: validate-release-runs.sh CI_RUN_ID REPRO_RUN_ID"

ci_run_id=$1
repro_run_id=$2
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$root"

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_SHA:?GITHUB_SHA is required}"
: "${GITHUB_REF:?GITHUB_REF is required}"

[[ $ci_run_id =~ ^[1-9][0-9]*$ ]] || die "CI run ID must be a positive integer"
[[ $repro_run_id =~ ^[1-9][0-9]*$ ]] || die "reproducibility run ID must be a positive integer"
[[ $GITHUB_REPOSITORY =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
    || die "invalid GitHub repository name"
[[ $GITHUB_SHA =~ ^[0-9a-f]{40}$ ]] || die "GITHUB_SHA is not a full commit SHA"
[[ $GITHUB_REF == refs/heads/main ]] || die "release validation must run from main"

command -v curl >/dev/null || die "curl is required"
command -v jq >/dev/null || die "jq is required"

jq -e '
  [.cells[].id] == ["ovs-u2204", "ovs-u2404", "ovn-u2204", "ovn-u2404"] and
  [.builders[].id] == ["u2204", "u2404"] and
  [.package_pairs[].id] == ["u2204", "u2404"]
' .github/ci-matrix.json >/dev/null \
    || die "release requires the exact locked product, builder, and package-pair matrices"

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

api_base="https://api.github.com/repos/$GITHUB_REPOSITORY/actions/runs"
fetch_json() {
    local url=$1
    local output=$2
    curl --fail --silent --show-error --location \
        --retry 3 --retry-all-errors \
        --header "Accept: application/vnd.github+json" \
        --header "Authorization: Bearer $GH_TOKEN" \
        --header "X-GitHub-Api-Version: 2022-11-28" \
        --output "$output" \
        "$url"
    jq -e . "$output" >/dev/null || die "GitHub API returned invalid JSON for $url"
}

fetch_json "$api_base/$ci_run_id" "$tmp/ci-run.json"
fetch_json "$api_base/$repro_run_id" "$tmp/repro-run.json"

assert_run() {
    local file=$1
    local expected_id=$2
    local expected_path=$3
    local description=$4
    local run_kind=$5

    jq -e \
        --argjson expected_id "$expected_id" \
        --arg expected_sha "$GITHUB_SHA" \
        --arg expected_path "$expected_path" \
        --arg run_kind "$run_kind" '
          .id == $expected_id and
          .status == "completed" and
          .conclusion == "success" and
          (.event == "workflow_dispatch" or ($run_kind == "ci" and .event == "push")) and
          .head_branch == "main" and
          .head_sha == $expected_sha and
          .path == $expected_path and
          .head_repository.full_name == env.GITHUB_REPOSITORY and
          (.run_attempt | type) == "number" and
          .run_attempt >= 1
        ' "$file" >/dev/null || die "$description is not a successful same-SHA main run"
}

assert_run "$tmp/ci-run.json" "$ci_run_id" ".github/workflows/ci.yml" "CI run" ci
assert_run "$tmp/repro-run.json" "$repro_run_id" ".github/workflows/reproducibility.yml" "reproducibility run" repro

ci_attempt=$(jq -r '.run_attempt' "$tmp/ci-run.json")
repro_attempt=$(jq -r '.run_attempt' "$tmp/repro-run.json")
fetch_json "$api_base/$ci_run_id/attempts/$ci_attempt/jobs?per_page=100" "$tmp/ci-jobs.json"
fetch_json "$api_base/$repro_run_id/attempts/$repro_attempt/jobs?per_page=100" "$tmp/repro-jobs.json"
fetch_json "$api_base/$ci_run_id/artifacts?per_page=100" "$tmp/ci-artifacts.json"
fetch_json "$api_base/$repro_run_id/artifacts?per_page=100" "$tmp/repro-artifacts.json"

assert_complete_job_page() {
    local file=$1
    local description=$2
    jq -e '.total_count <= 100 and .total_count == (.jobs | length)' "$file" >/dev/null \
        || die "$description job list is incomplete or unexpectedly large"
}

assert_exact_job_set() {
    local file=$1
    local expected=$2
    local description=$3

    jq -e --argjson expected "$expected" '
      .total_count == ($expected | length) and
      ([.jobs[].name] | sort) == ($expected | sort) and
      all(.jobs[]; .status == "completed" and .conclusion == "success")
    ' "$file" >/dev/null || die "$description job set is missing, duplicated, unexpected, or unsuccessful"
}

assert_artifact_set() {
    local file=$1
    local expected=$2
    local description=$3

    jq -e --argjson expected "$expected" '
      .total_count <= 100 and
      .total_count == (.artifacts | length) and
      (.artifacts | length) == ($expected | length) and
      ([.artifacts[].name] | sort) == ($expected | sort) and
      all(.artifacts[]; .expired == false and .size_in_bytes > 0)
    ' "$file" >/dev/null || die "$description artifact set is missing, duplicated, unexpected, empty, or expired"
}

assert_complete_job_page "$tmp/ci-jobs.json" "CI"
assert_complete_job_page "$tmp/repro-jobs.json" "reproducibility"

ci_jobs=$(jq -cn '[
  "plan",
  "build / ovs-u2204",
  "build / ovs-u2404",
  "build / ovn-u2204",
  "build / ovn-u2404",
  "builder / u2204",
  "builder / u2404",
  "package-consistency / u2204",
  "package-consistency / u2404"
]')
repro_jobs=$(jq -cn '[
  "plan",
  "reproducibility-build / ovs-u2204 / a",
  "reproducibility-build / ovs-u2204 / b",
  "reproducibility-build / ovs-u2404 / a",
  "reproducibility-build / ovs-u2404 / b",
  "reproducibility-build / ovn-u2204 / a",
  "reproducibility-build / ovn-u2204 / b",
  "reproducibility-build / ovn-u2404 / a",
  "reproducibility-build / ovn-u2404 / b",
  "compare / ovs-u2204",
  "compare / ovs-u2404",
  "compare / ovn-u2204",
  "compare / ovn-u2404"
]')
ci_artifacts=$(jq -cn '[
  "debs-ovs-u2204",
  "debs-ovs-u2404",
  "debs-ovn-u2204",
  "debs-ovn-u2404",
  "builder-u2204",
  "builder-u2404"
]')
repro_artifacts=$(jq -cn '[
  "repro-ovs-u2204-a",
  "repro-ovs-u2204-b",
  "repro-ovs-u2404-a",
  "repro-ovs-u2404-b",
  "repro-ovn-u2204-a",
  "repro-ovn-u2204-b",
  "repro-ovn-u2404-a",
  "repro-ovn-u2404-b"
]')

[[ $(jq 'length' <<< "$ci_jobs") == 9 ]] || die "internal CI job contract is not nine jobs"
[[ $(jq 'length' <<< "$repro_jobs") == 13 ]] \
    || die "internal reproducibility job contract is not thirteen jobs"

assert_exact_job_set "$tmp/ci-jobs.json" "$ci_jobs" "nine-job CI"
assert_exact_job_set "$tmp/repro-jobs.json" "$repro_jobs" "thirteen-job reproducibility"
assert_artifact_set "$tmp/ci-artifacts.json" "$ci_artifacts" "CI release input"
assert_artifact_set "$tmp/repro-artifacts.json" "$repro_artifacts" "reproducibility evidence"

echo "validated CI run $ci_run_id and reproducibility run $repro_run_id for $GITHUB_SHA"
