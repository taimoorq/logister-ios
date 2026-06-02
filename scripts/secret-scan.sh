#!/usr/bin/env bash
set -euo pipefail

pattern='(github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN (RSA|OPENSSH|DSA|EC|PRIVATE) KEY-----|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35})'

if git grep --untracked -n -I -E "$pattern" -- .; then
  echo "Potential secret material found in tracked files." >&2
  exit 1
fi

sensitive_untracked="$(git ls-files --others --exclude-standard | grep -E '(^|/)(\.env(\..*)?|AuthKey_.*\.p8|private-key\..*|.*\.(p8|p12|pem|key|cer|csr|gpg|pgp|kbx|mobileprovision|provisionprofile))$' || true)"

if [ -n "$sensitive_untracked" ]; then
  echo "Sensitive-looking untracked files are present:" >&2
  echo "$sensitive_untracked" >&2
  exit 1
fi
