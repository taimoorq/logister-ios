# logister-ios

iOS SDK for Logister.

This repository is the canonical home for the iOS package add-on. Build Swift Package Manager source, examples, tests, and release notes here rather than inside the Rails app.

## Current Scope

- Swift Package Manager library product named `Logister`.
- Async/await client backed by `URLSession`.
- Injectable transport for tests or alternate networking stacks.
- Async token-provider based authentication with short-lived mobile ingest tokens.
- Typed JSON context values for safe event metadata.
- Client methods for errors, logs, metrics, transactions, spans, and check-ins.
- Capture iOS app metadata such as bundle ID, app version, build number, iOS version, device model, locale, and session ID.

Automatic crash breadcrumbs, screen timing, URLSession timing, retry, and offline-queue instrumentation should remain opt-in while privacy defaults are settled.

## Install

Add the public Swift package with Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/taimoorq/logister-ios.git", from: "0.1.2")
]
```

Then depend on the library product:

```swift
.product(name: "Logister", package: "logister-ios")
```

- Swift Package Manager URL: https://github.com/taimoorq/logister-ios.git
- Current release: https://github.com/taimoorq/logister-ios/releases/tag/v0.1.2
- iOS integration docs: https://docs.logister.org/integrations/ios/

## Swift Package Release

Swift Package Manager distribution does not require a package registry account.
After CI passes on `main`, the release-from-main workflow creates the matching
version tag from `VERSION` and dispatches the release workflow. You can also
push a semantic version tag manually:

```bash
git tag v0.1.2
git push origin v0.1.2
```

The release workflow runs the secret scan and test suite, then creates or
updates the matching GitHub Release. SwiftPM consumers resolve the package from
the Git tag itself.

## Basic Usage

Do not compile a Logister project API key into an iOS app. The iOS SDK requires
an async `LogisterTokenProvider`; implement it by calling your own backend. Your
backend should authenticate the app/session, use its server-side Logister
project API key to mint a short-lived token with
`POST /api/v1/mobile_ingest_tokens`, and return that token to the app.

```swift
import Foundation
import Logister

struct AppBackendTokenProvider: LogisterTokenProvider {
    func fetchToken() async throws -> LogisterToken {
        // Call your app backend, not Logister directly. Return the token and
        // expires_at value from your backend's mobile token response.
        LogisterToken(
            token: "short-lived-mobile-token",
            expiresAt: Date().addingTimeInterval(900)
        )
    }
}

let client = LogisterClient(
    baseURL: URL(string: "https://your-logister-host.example")!,
    tokenProvider: AppBackendTokenProvider(),
    environment: "production",
    release: "1.4.0+42",
    repository: "acme/ios-app",
    commitSHA: "4f8c2d1",
    branch: "main",
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

When the Logister project is connected to a GitHub repository, `repository`,
`commitSHA`, and `branch` help source-aware error details resolve frames to the
right code. CI/CD systems should record release-to-commit deployment mappings
with the Logister HTTP API `POST /api/v1/deployments` endpoint.

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
use placeholder short-lived mobile tokens, example hostnames, and environment
variables instead of real project credentials.

Do not commit Apple signing certificates, provisioning profiles, App Store
Connect keys, Logister project API keys, mobile token issuer secrets, Cloudflare
tokens, `.env` files, or machine-specific configuration.

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
