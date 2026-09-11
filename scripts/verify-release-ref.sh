#!/usr/bin/env bash
set -euo pipefail
# Manual dispatch executes the current workflow but must build reviewed tagged source.
[[ "${RELEASE_TAG:-}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid stable release tag'; exit 1; }
git fetch --no-tags origin '+refs/heads/main:refs/remotes/origin/main'
test "$(git rev-parse HEAD)" = "$(git rev-parse "refs/tags/${RELEASE_TAG}^{commit}")"
git merge-base --is-ancestor "refs/tags/${RELEASE_TAG}^{commit}" refs/remotes/origin/main
if [ -n "${GITHUB_ENV:-}" ]; then
  echo "SOURCE_DATE_EPOCH=$(git show -s --format=%ct HEAD)" >> "$GITHUB_ENV"
fi
