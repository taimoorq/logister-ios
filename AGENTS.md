# Logister Apple SDK Agent Notes

This is a public Swift Package repository. Never commit credentials, private
telemetry, customer data, signing material, or local Xcode state.

## Dependency and platform maintenance

- `VERSION` is the release-version source of truth.
- `Package.swift` owns the Swift tools version and supported Apple platform
  floors. Treat changes to those floors as compatibility changes and test them
  on the hosted macOS runner before release.
- Keep Swift Package Manager and GitHub Actions Dependabot updates enabled. Pin
  Actions to full commit SHAs and retain a readable version comment.

## Verification

Run before handoff or release:

```bash
bash scripts/secret-scan.sh
swift test
```

## Release contract

- Update `VERSION` and release notes together when package behavior changes.
- Merging a new version to `main` runs CI, creates `vX.Y.Z`, and explicitly
  dispatches `release.yml`. Keep the explicit dispatch because tags pushed with
  `GITHUB_TOKEN` do not start tag-push workflows.
- Swift Package Manager consumes the Git tag directly; there is no separate
  registry publication. The release workflow must verify `VERSION`, test the
  tagged source, and then create the matching GitHub Release.
- Never move a tag after consumers could have resolved it. Use a new patch
  version for corrections.
- Verify the tag and GitHub Release before calling the release complete:

```bash
git ls-remote --tags origin refs/tags/vX.Y.Z
gh release view vX.Y.Z
```
