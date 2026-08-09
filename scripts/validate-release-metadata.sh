#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

version="$(tr -d '[:space:]' < VERSION)"
if ! echo "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$'; then
  echo "VERSION must contain a semantic release version." >&2
  exit 1
fi
if ! grep -Fq "static let version = \"$version\"" Sources/Logister/LogisterPlatformContext.swift; then
  echo "LogisterSDK.version does not match VERSION $version." >&2
  exit 1
fi
if ! grep -Eq "^## v${version}([[:space:]]|-|$)" CHANGELOG.md; then
  echo "CHANGELOG.md is missing a v$version heading." >&2
  exit 1
fi
if ! grep -Fq "from: \"$version\"" README.md; then
  echo "README.md does not show the current Swift package version $version." >&2
  exit 1
fi

echo "Release metadata is consistent for v$version."
