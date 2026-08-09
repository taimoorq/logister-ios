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
- An opt-in MetricKit collector for crash, hang, excessive-CPU, excessive-disk-write,
  and slow-launch
  diagnostics. Safe collection is the default: private reason text is omitted,
  hierarchical sampled call trees and typed measurements are bounded, raw
  addresses retain lossless hexadecimal identity, source reporting/build/device
  metadata is retained, and diagnostics receive stable IDs so OS redelivery is
  idempotent. Resource and launch diagnostics do not invent fatality.
- Actor-owned durable, bounded, process-local delivery scoped by endpoint,
  application/service, and optional client scope; tokens are never persisted.
- Bounded transient retries for timeouts, rate limits, and server errors, with
  `Retry-After`, one-time `401` refresh, and poison-response discard.
- Runtime collection disable/purge, an opt-in rotating delivery-installation
  pseudonym, recursive credential/URL redaction, payload budgets, a final
  `beforeSend` hook, and a non-sensitive health snapshot.

`captureException` is a handled report; it is not an automatic fatal-crash
handler. Set its policy to `typeAndStacktrace` when error text has not received a
privacy review. MetricKit is the opt-in source for OS-delivered diagnostics and
uses that safe policy by default. Automatic screen timing and URLSession timing
are not included in the current package.

## Install

Add the public Swift package with Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/taimoorq/logister-ios.git", from: "0.5.0")
]
```

Then depend on the library product:

```swift
.product(name: "Logister", package: "logister-ios")
```

- Swift Package Manager URL: https://github.com/taimoorq/logister-ios.git
- Current release: https://github.com/taimoorq/logister-ios/releases/tag/v0.5.0
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
    platformContextPolicy: .minimized,
    configuration: LogisterConfiguration(
        // Set this when one app configures multiple logical Logister clients.
        storageScope: "primary-mobile-project",
        installationTrackingEnabled: true,
        beforeSend: { event in
            // Synchronously redact or return nil to discard. Do not do I/O.
            event
        }
    )
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

Every event receives its UUID and exact capture date before asynchronous work,
then is persisted before token acquisition or network delivery. The queue lives
in Application Support, is excluded from backup, and is scoped by endpoint,
bundle/service, optional `storageScope`, and process name. The main app and each
extension therefore own separate queues; sharing one queue through an App Group
across multiple processes is intentionally unsupported. A custom App Group
directory is suitable only with a distinct scope per process.

Call `flushQueuedEvents()` after authentication to force a retry. A queued
response has `deliveryState == .queued` and `accepted == false`. Call
`setCollectionEnabled(false)` to stop capture and, by default, purge this
client's queue and rotating installation pseudonym. `healthSnapshot()` exposes
only collection state, queue/drop counts, last delivery/error, MetricKit
subscription, decoder, and installation-capability state.

The optional installation pseudonym is random, endpoint/project/process scoped,
rotated, and labeled `delivery_installation`; it is not IDFA, IDFV, or a
historical MetricKit source session. `LogisterPayloadPolicy` bounds depth, item
count, strings, and envelope bytes and removes common credential keys, Bearer
values, URL query data, IDFA/IDFV, and hardware identifiers. The final
`beforeSend` result is sanitized again and cannot replace UUID, occurrence-time
precision, or evidence provenance.

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
excessive-CPU, excessive-disk-write, and iOS 16+ slow-launch diagnostic through the normal short-lived-token
path and uses a deterministic event UUID so a repeated payload does not create
another Logister occurrence. Safe mode sends normalized exception type, codes,
signals, privacy-filtered immutable source evidence, bounded frames, sampled
call trees, and typed measurements without
termination or exception reason text. The collector carries the payload's
reporting interval and source app version/build, hardware identifier, OS build,
architecture, and TestFlight flag; it never substitutes uploader-time app,
device, release, or occurrence facts. Use `.full` only after reviewing those
fields for the app's data policy.

For address-only production frames, upload the matching zipped dSYM from the
exported Xcode archive from the project's **Artifacts** page or trusted CI.
Logister verifies the binary UUID and architecture in private archive storage,
then resolves eligible stored frames on an Apple-toolchain worker while
preserving every raw address.
App Store Connect power/performance
reports are configured in the same settings area but remain a separate,
freshness-labelled aggregate; they are not added to SDK or MetricKit counts.

## dSYM upload in CI

Archive the exact dSYM produced by the release build, read its UUID and
architecture with `dwarfdump`, and upload it with a separately scoped Logister
CLI token. For example, an Xcode Cloud or CI step can run:

```bash
DSYM_PATH="$ARCHIVE_PATH/dSYMs/Shop.app.dSYM"
DSYM_ZIP="$RUNNER_TEMP/Shop.app.dSYM.zip"
ditto -c -k --keepParent "$DSYM_PATH" "$DSYM_ZIP"
dwarfdump --uuid "$DSYM_PATH"

LOGISTER_HOST=https://logister.example.com \
LOGISTER_TOKEN="$LOGISTER_ARTIFACT_TOKEN" \
logister artifacts upload-ios \
  --project "$LOGISTER_PROJECT" \
  --file "$DSYM_ZIP" \
  --app-identifier com.acme.shop \
  --version-name "$MARKETING_VERSION" \
  --version-code "$CURRENT_PROJECT_VERSION" \
  --binary-uuid AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE \
  --architecture arm64
```

Invoke the upload once for each binary UUID and architecture represented by the
archive, including app extensions and embedded frameworks. Use an expiring,
project-limited CLI token approved with the additive `artifacts:write` scope;
never reuse the app's mobile ingest token or embed the CI token in the app.
Verification proves that the uploaded artifact contains the declared binary
identity. It does not, by itself, mean existing events have been symbolicated.

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

A permanent non-2xx response remains non-accepted and is removed so it cannot
block later envelopes. An exhausted transient or authentication failure remains
durably queued. The package never reports queued delivery as server acceptance.

## Privacy manifest

The package bundles `PrivacyInfo.xcprivacy` as an explicit Swift Package
resource. It declares diagnostic/performance/product-interaction data, optional
user and random device identifiers, and custom event data because host apps can
enable or provide those fields. These are declared as potentially linked,
non-tracking data used for app functionality (and analytics where applicable).
The manifest declares no tracking domains and no required-reason APIs. Generate
and review the consuming app's Xcode privacy report whenever host collection
changes; the app publisher remains responsible for its App Store privacy label.

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
