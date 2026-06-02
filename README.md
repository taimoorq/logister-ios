# logister-ios

iOS SDK for Logister.

This repository is the canonical home for the iOS package add-on. Build Swift Package Manager source, examples, tests, and release notes here rather than inside the Rails app.

## Current Scope

- Swift Package Manager library product named `Logister`.
- Async/await client backed by `URLSession`.
- Injectable transport for tests or alternate networking stacks.
- Typed JSON context values for safe event metadata.
- Client methods for errors, logs, metrics, transactions, spans, and check-ins.
- Capture iOS app metadata such as bundle ID, app version, build number, iOS version, device model, locale, and session ID.

Automatic crash breadcrumbs, screen timing, URLSession timing, retry, and offline-queue instrumentation should remain opt-in while privacy defaults are settled.

## Install

The package is not published yet. Once the repository is public and tagged, add it with Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/taimoorq/logister-ios.git", from: "0.1.0")
]
```

Then depend on the library product:

```swift
.product(name: "Logister", package: "logister-ios")
```

## Swift Package Release

Swift Package Manager distribution does not require a package registry account.
Publishing a new package version means pushing a semantic version tag:

```bash
git tag v0.1.0
git push origin v0.1.0
```

The release workflow runs the secret scan and test suite, then creates or
updates the matching GitHub Release. SwiftPM consumers resolve the package from
the Git tag itself.

## Basic Usage

```swift
import Foundation
import Logister

let client = LogisterClient(
    apiKey: "your-project-api-token",
    baseURL: URL(string: "https://your-logister-host.example")!,
    environment: "production",
    release: "1.4.0+42",
    service: Bundle.main.bundleIdentifier,
    defaultContext: [
        "app_version": .string("1.4.0"),
        "build_number": .string("42"),
        "device_model": .string("iPhone")
    ]
)

try await client.captureMessage(
    "Checkout opened",
    options: LogisterEventOptions(
        sessionID: "session-123",
        context: ["screen_name": .string("Checkout")]
    )
)

try await client.captureMetric("cart.item_count", value: 3, unit: "count")

try await client.captureTransaction(
    "screen.load",
    durationMs: 142.7,
    options: LogisterEventOptions(context: ["screen_name": .string("Checkout")])
)
```

## Spans And Check-ins

```swift
try await client.captureSpan(
    LogisterSpan(
        traceID: "trace-123",
        spanID: "span-456",
        parentSpanID: "span-root",
        name: "GET /checkout",
        kind: "http",
        status: "ok",
        durationMs: 42.5,
        context: ["screen_name": .string("Checkout")]
    )
)

try await client.checkIn(
    "daily-sync",
    status: "ok",
    options: LogisterEventOptions(
        durationMs: 812.4,
        context: ["expected_interval_seconds": .number(86_400)]
    )
)
```

## Verification

The package currently has envelope-focused tests:

```bash
swift test
```

## Public Repository Hygiene

This repository is designed to be public and open source. Keep examples generic:
use placeholder API tokens, example hostnames, and environment variables instead
of real project credentials.

Do not commit Apple signing certificates, provisioning profiles, App Store
Connect keys, Logister project API keys, Cloudflare tokens, `.env` files, or
machine-specific configuration.

CI runs `scripts/secret-scan.sh`, and dependency updates are tracked by
`.github/dependabot.yml` for Swift Package Manager and GitHub Actions.

Swift Package Manager distribution from a public GitHub repository does not
require a package registry secret. If a future release workflow needs Apple
credentials, set them with the GitHub CLI, for example:

```bash
gh secret set APP_STORE_CONNECT_KEY_ID --repo taimoorq/logister-ios
gh secret set APP_STORE_CONNECT_ISSUER_ID --repo taimoorq/logister-ios
gh secret set APP_STORE_CONNECT_PRIVATE_KEY --repo taimoorq/logister-ios < AuthKey_PRIVATE.p8
```

The Rails-side integration plan lives in the `logister` Rails repository under
`docs/cloudflare-mobile-integrations-plan.md`.
