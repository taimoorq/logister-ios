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
- Versioned Apple telemetry with automatic bundle, version/build, Apple platform,
  OS/build, device family/model, architecture, locale, and SDK context.
- Explicit handled/fatal semantics, structured threads and frames, bounded
  breadcrumbs, and opt-in session, rotating installation-hash, distribution,
  foreground, and source context.
- An opt-in MetricKit collector for crash, hang, CPU-exception, and disk-write
  diagnostics. Safe collection is the default: raw payloads and termination
  reasons are omitted, threads/frames are bounded, and diagnostic payloads
  receive stable event IDs so OS redelivery is idempotent at ingestion.
- Bounded transient retries for timeouts, rate limits, and server errors, with
  support for `Retry-After`.

`captureException` is a handled report; it is not an automatic fatal-crash
handler. Set its policy to `typeAndStacktrace` when error text has not received a
privacy review. MetricKit is the opt-in source for OS-delivered diagnostics and
uses that safe policy by default. Automatic screen timing, URLSession timing,
and a persistent offline queue are not included in the current package.

## Install

Add the public Swift package with Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/taimoorq/logister-ios.git", from: "0.3.0")
]
```

Then depend on the library product:

```swift
.product(name: "Logister", package: "logister-ios")
```

- Swift Package Manager URL: https://github.com/taimoorq/logister-ios.git
- Current release: https://github.com/taimoorq/logister-ios/releases/tag/v0.3.0
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
        service: Bundle.main.bundleIdentifier,
        exceptionDataPolicy: .typeAndStacktrace,
        platformContextPolicy: .minimized
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

Open the Logister project inbox and confirm that the handled Swift error appears. With the safe policy, the event identifies the error type without sending the localized **README test error** text. If the response is not accepted, check the base URL, token expiry, and your backend's mobile-token response before changing SDK code.

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
    retryPolicy: .default,
    exceptionDataPolicy: .typeAndStacktrace,
    platformContextPolicy: .minimized
)

try await client.captureMessage(
    "Checkout opened",
    options: LogisterEventOptions(
        sessionID: "session-123",
        installationIDHash: "rotating-random-pseudonym",
        distributionChannel: "testflight",
        inForeground: true,
        breadcrumbs: [
            LogisterBreadcrumb(category: "navigation", message: "Opened checkout")
        ],
        context: ["app": .object(["screen": .string("Checkout")])]
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

The standard platform policy derives the bundle identifier, app version/build,
Apple platform, OS version/build, device model/family, architecture, locale, SDK
version, and a default `version+build` release. The minimized policy retains
compatibility context but omits exact model, locale, architecture, and OS build.
Supply overrides only when your release model requires them. Never send IDFA,
raw IDFV, serial numbers, or another stable hardware identifier; the SDK
recursively removes common aliases.

## MetricKit diagnostics

Keep one collector alive for the app lifetime and start it after creating the
client:

```swift
import Logister

@available(iOS 15.0, *)
final class AppDiagnostics {
    let metricKitCollector: LogisterMetricKitCollector

    init(client: LogisterClient) {
        metricKitCollector = LogisterMetricKitCollector(
            client: client,
            dataPolicy: .typeAndStacktrace,
            onUploadError: { message in
                // Record locally without including credentials or payload data.
                print("MetricKit upload failed: \(message)")
            }
        )
        metricKitCollector.start()
    }

    deinit {
        metricKitCollector.stop()
    }
}
```

MetricKit delivery is delayed and controlled by the operating system. It is not
a real-time crash callback. The collector uploads each crash, hang,
CPU-exception, and disk-write diagnostic through the normal short-lived-token
path and uses a deterministic event UUID so a repeated payload does not create
another Logister occurrence. Safe mode sends normalized exception type, codes,
signals, and bounded frames without the raw MetricKit payload or termination
reason. Use `.full` only after reviewing those fields for the app's data policy.

For address-only production frames, upload the matching zipped dSYM from the
exported Xcode archive in Project Settings → Integrations. Logister verifies the binary UUID and
architecture in private archive storage. App Store Connect power/performance
reports are configured in the same settings area but remain a separate,
freshness-labelled aggregate; they are not added to SDK or MetricKit counts.

## Delivery behavior

The default retry policy makes at most three attempts for network failures,
HTTP 408/425/429, and 5xx responses. It honors `Retry-After` up to the configured
maximum delay. Disable it or tune the bounds explicitly:

```swift
let client = LogisterClient(
    baseURL: URL(string: "https://your-logister-host.example")!,
    tokenProvider: AppBackendTokenProvider(appBackend: appBackend),
    retryPolicy: LogisterRetryPolicy(
        maximumAttempts: 2,
        baseDelay: 0.5,
        maximumDelay: 10
    )
)
```

A non-2xx response remains non-accepted, and an exhausted transport failure is
still thrown to the caller. The package does not silently report queued delivery
as server acceptance.

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
