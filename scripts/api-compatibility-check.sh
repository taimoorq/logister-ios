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
swift package diagnose-api-breaking-changes "$baseline_tag"
