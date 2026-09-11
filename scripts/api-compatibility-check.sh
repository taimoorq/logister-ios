#!/usr/bin/env bash
set -euo pipefail

current_version="$(tr -d '[:space:]' < VERSION)"
baseline_tag="${API_BASELINE_TAG:-}"

if [ -z "$baseline_tag" ]; then
  while IFS= read -r candidate; do
    candidate_sha="$(git rev-list -n 1 "$candidate")"
    head_sha="$(git rev-parse HEAD)"
    if [ "${candidate#v}" != "$current_version" ] || [ "$candidate_sha" != "$head_sha" ]; then
      baseline_tag="$candidate"
      break
    fi
  done < <(git tag --merged HEAD --list 'v*' --sort=-v:refname)
fi

if [ -z "$baseline_tag" ]; then
  echo "No prior release tag found; skipping public API compatibility check."
  exit 0
fi

echo "Checking public API compatibility against $baseline_tag"
arguments=()
# Two reviewed changes accompany the pre-1.0 minor migration. Keep this limited
# to that exact transition; new breakages still fail and future baselines reset it.
if [ "$baseline_tag" = "v0.3.0" ] && [ "$current_version" = "0.5.0" ]; then
  arguments+=(--breakage-allowlist-path scripts/api-breakages-0.3-to-0.5.txt)
fi
swift package diagnose-api-breaking-changes "${arguments[@]}" "$baseline_tag"
