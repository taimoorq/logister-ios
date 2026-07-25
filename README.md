# logister-ios

iOS and Apple-platform SDK for sending errors, logs, metrics, transactions, spans, and scheduled-job check-ins to Logister.

The Swift package supports iOS 15+, macOS 13+, tvOS 15+, and watchOS 8+. It uses async/await and `URLSession` and ships one library product named `Logister`.

## Before you start

Do not compile a long-lived Logister project API key into an Apple app. The SDK asks your own authenticated backend for a short-lived token. Your backend mints that token with `POST /api/v1/mobile_ingest_tokens`; the SDK caches it until it is close to expiring.

```text
Apple app → your authenticated backend → Logister mobile token endpoint
Apple app → Logister ingest endpoint with the short-lived token
```

## What it supports

- Swift Package Manager library product named `Logister`.
- Async/await client backed by `URLSession`.
- Injectable transport for tests or alternate networking stacks.
- Async token-provider based authentication with short-lived mobile ingest tokens.
- Typed JSON context values for safe event metadata.
- Client methods for errors, logs, metrics, transactions, spans, and check-ins.
- Configurable service, source, release, session, and app/device context on every event.

Automatic crash breadcrumbs, screen timing, URLSession timing, retries, and offline queues are not included in the current package.

## Install

Add the public Swift package with Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/taimoorq/logister-ios.git", from: "0.1.3")
]
```

Then depend on the library product:

```swift
.product(name: "Logister", package: "logister-ios")
```

- Swift Package Manager URL: https://github.com/taimoorq/logister-ios.git
- Current release: https://github.com/taimoorq/logister-ios/releases/tag/v0.1.3
- iOS integration docs: https://logister.org/docs/integrations/ios/

## Quick start

Implement `LogisterTokenProvider` with your existing API client. The protocol below represents the endpoint you add to your own backend:

```swift
import Foundation
import Logister

struct MobileTokenResponse: Sendable {
    let token: String
    let expiresAt: Date
}

protocol AppBackend: Sendable {
    func fetchLogisterMobileToken() async throws -> MobileTokenResponse
}

struct AppBackendTokenProvider: LogisterTokenProvider {
    let appBackend: any AppBackend

    func fetchToken() async throws -> LogisterToken {
        let response = try await appBackend.fetchLogisterMobileToken()
        return LogisterToken(
            token: response.token,
            expiresAt: response.expiresAt
        )
    }
}

func sendReadmeTest(using appBackend: any AppBackend) async throws {
    let logister = LogisterClient(
        baseURL: URL(string: "https://logister.example.com")!,
        tokenProvider: AppBackendTokenProvider(appBackend: appBackend),
        environment: "development",
        release: Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String,
        service: Bundle.main.bundleIdentifier
    )

    let response = try await logister.captureException(
        NSError(
            domain: "README",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "README test error"]
        ),
        options: LogisterEventOptions(
            fingerprint: "readme-test-error",
            context: ["screen_name": .string("Checkout")]
        )
    )

    precondition(response.accepted)
}
```

Open the Logister project inbox and confirm that **README test error** appears. If the response is not accepted, check the base URL, token expiry, and your backend's mobile-token response before changing SDK code.

## Basic Usage

Building on `AppBackendTokenProvider` from the quick start, this example adds source context and sends several telemetry types.

```swift
import Foundation
import Logister

let client = LogisterClient(
    baseURL: URL(string: "https://your-logister-host.example")!,
    tokenProvider: AppBackendTokenProvider(appBackend: appBackend),
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

## Development

The package currently has envelope-focused tests:

```bash
swift test
```

## Swift Package release

`VERSION` is the package version source of truth. After CI passes on `main`, the release-from-main workflow creates the matching `vX.Y.Z` tag and explicitly dispatches `release.yml`. The release reruns the secret scan and tests before creating the GitHub Release.

Swift Package Manager resolves the source from the Git tag; there is no separate registry upload. Verify the tag and GitHub Release before calling a release complete:

```bash
git ls-remote --tags origin refs/tags/vX.Y.Z
gh release view vX.Y.Z
```

## Security and contributing

This repository is designed to be public and open source. Keep examples generic:
use placeholder short-lived mobile tokens, example hostnames, and environment
variables instead of real project credentials.

Do not commit Apple signing certificates, provisioning profiles, App Store
Connect keys, Logister project API keys, mobile token issuer secrets, Cloudflare
tokens, `.env` files, or machine-specific configuration.

CI runs `scripts/secret-scan.sh`, and dependency updates are tracked by
`.github/dependabot.yml` for Swift Package Manager and GitHub Actions.

Swift Package Manager distribution from a public GitHub repository does not require a package registry secret. The Git tag is the package release; do not move a tag after consumers could have resolved it.

For server-side token issuance and mobile deployment guidance, read the [iOS integration guide](https://logister.org/docs/integrations/ios/) and the main app's [mobile add-ons reference](https://github.com/taimoorq/logister/blob/main/docs/mobile-add-ons.md).
