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
- Async/await client backed by a dedicated `URLSession` with bounded timeouts,
  no cookies or cache, no redirects, and https-only endpoints.
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
- Bounded, jittered transient retries for timeouts, rate limits, and server
  errors, with `Retry-After`, one-time `401` refresh, and poison-response
  discard.
- Runtime collection disable/purge, an opt-in rotating delivery-installation
  pseudonym, the shared Logister redaction rule, payload budgets that match the
  server's limits, a final `beforeSend` hook, and a non-sensitive health
  snapshot.

`captureException` is a handled report; it is not an automatic fatal-crash
handler. The default `typeAndStacktrace` policy sends the error type and stack
only. `.full` adds the error's `localizedDescription`, NSError domain and code,
and a reviewed `userInfo` subset (failure reason, recovery suggestion, failing
URL without its query, and underlying error domains and codes); choose it only
after reviewing that text. MetricKit is the opt-in source for OS-delivered
diagnostics and uses the safe policy by default. Automatic screen timing and URLSession timing
are not included in the current package.

## Install

Add the public Swift package with Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/taimoorq/logister-ios.git", from: "0.7.0")
]
```

Then depend on the library product:

```swift
.product(name: "Logister", package: "logister-ios")
```

- Swift Package Manager URL: https://github.com/taimoorq/logister-ios.git
- Release version: https://github.com/taimoorq/logister-ios/releases/tag/v0.7.0
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
historical MetricKit source session. The final `beforeSend` result is
sanitized again and cannot replace UUID, occurrence-time precision, or evidence
provenance.

### Redaction and payload limits

Every event passes through the shared Logister redaction rule before it is
queued, including context, breadcrumbs and their data, span and HTTP fields,
exception data, MetricKit evidence, and anything `beforeSend` adds.

- A key is sensitive when, after lowercasing and removing every
  non-alphanumeric character, it equals one of
  `LogisterPayloadPolicy.defaultSensitiveKeys` (`password`, `passwd`, `pwd`,
  `secret`, `token`, `apikey`, `authorization`, `proxyauthorization`, `cookie`,
  `setcookie`, `sessiontoken`, `sessionkey`, `credential`, `credentials`,
  `privatekey`, `clientsecret`, `accesstoken`, `refreshtoken`, `idtoken`,
  `authtoken`, `xapikey`, `xauthtoken`, `xaccesstoken`, `xcsrftoken`,
  `xxsrftoken`, `signature`, `ssn`, `creditcard`, `cardnumber`, `cvv`), or
  contains `token`, `secret`, `password`, `passwd`, `apikey`, `authorization`,
  `credential` or `cookie`. So `accessToken`, `x-api-key` and `Set-Cookie` all
  match. The value becomes `"[REDACTED]"`.
- Strings are scrubbed for `Bearer <token>` and `Basic <credentials>`, JWTs,
  and `lgst_` keys. URLs inside strings keep scheme, host and path; userinfo,
  query and fragment are removed.
- IDFA, IDFV, serial numbers and common hardware-identifier keys are removed.
- The SDK's own envelope fields (`uuid`, `event_type`, `occurred_at`,
  `trace_id`, `request_id`, `session_id`) are never redacted.

Add your own keys by extending the default list. Entries are normalized the
same way and must match exactly:

```swift
let configuration = LogisterConfiguration(
    payloadPolicy: LogisterPayloadPolicy(
        sensitiveKeys: LogisterPayloadPolicy.defaultSensitiveKeys.union(["pin_code", "account-number"])
    )
)
```

`LogisterPayloadPolicy` also bounds depth, items, string length, total object
keys (`maximumKeys`, 512) and bytes (`maximumEnvelopeBytes`, 1,000,000). The key
and byte defaults match the Logister server, which rejects larger events. When a
budget runs out, the SDK keeps every envelope field and its own platform and
error context, keeps small objects before large ones and the newest
breadcrumbs, drops the rest, and sets `context._truncated` to `true`. An event
that is still too large is shrunk further rather than dropped.

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
signals, source metadata and reporting interval, bounded frames, sampled call
trees for hang and resource diagnostics, and typed measurements without
termination or exception reason text. Crash threads are sent once as flattened
frames with the crashed thread first, so a large crash keeps its crashed thread
when the payload budget trims other threads. The collector carries the payload's
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

The default transport sends on its own ephemeral `URLSession` with a 15 second
request timeout and a 60 second resource timeout. It stores no cookies or
cache and does not follow redirects, so the bearer token only reaches the
configured endpoint; point the client at the final URL. The endpoint must use
https. Plain http is accepted only for `localhost`, `*.localhost`, `127.x.x.x`
and `::1`, or when you opt in for a development server:

```swift
var configuration = LogisterConfiguration()
configuration.allowsInsecureTransport = true // local development only
```

Without it, capture against an http endpoint returns a `.dropped` response and
nothing is queued.

`LogisterTokenProvider.fetchToken()` gets `tokenProviderTimeout` seconds (30 by
default) before the attempt fails and the event stays queued.

The default retry policy makes at most three attempts for network failures,
HTTP 408/425/429, and 5xx responses. Computed delays are jittered between half
and all of the exponential backoff. It honors `Retry-After` up to the configured
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

On a `401` the SDK fetches a new token once and resends. If the server still
answers `401`, or the token provider fails or times out, the event stays queued
with backoff until it is delivered, expires (`maximumQueueAge`) or is evicted by
the queue bounds. Any other permanent non-2xx response, including `403`,
remains non-accepted and is removed so it cannot block later envelopes. An
exhausted transient failure also remains durably queued. The package never
reports queued delivery as server acceptance.

Each queued event is its own file, so an enqueue, delivery or retry writes only
that event.

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

The tests cover envelopes, payload budgets against the server's limits,
redaction, delivery, and request correlation:

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


### Upgrading to 0.7.0

0.7.0 has no source-breaking API changes, but several defaults change:

- Initializers that do not pass `exceptionDataPolicy`, including the deprecated
  ones, now use `.typeAndStacktrace`. Pass `.full` explicitly to keep error
  messages, and note that `.full` now sends `localizedDescription` and a
  reviewed `userInfo` subset instead of `String(describing:)`.
- Sensitive values are replaced with `"[REDACTED]"` instead of removing the key,
  and many more keys match (see "Redaction and payload limits").
- Events are held to 512 object keys and 1,000,000 bytes. Large contexts and
  long breadcrumb lists are trimmed and marked with `context._truncated`
  instead of the whole event being rejected.
- http endpoints are refused unless the host is loopback or
  `allowsInsecureTransport` is set. Redirects are no longer followed.
- A repeated `401` keeps the event queued instead of discarding it.
- The queue moves from `delivery-<scope>.json` to a `delivery-<scope>/`
  directory with one file per event. Existing queued events are migrated on
  first launch.
- MetricKit crash events no longer include `diagnostic.call_stack_tree` (it
  repeated the thread frames) or `source_evidence.diagnostic` (the raw payload).
  With `.full`, the raw payload is still sent as `context.metrickit`.

### Migrating from 0.3 to 0.5

The durable queue binds events to the endpoint that captured them. `endpoint` is
now read-only: create another `LogisterClient` to change servers, rather than
mutating a client with queued events. This intentional pre-1.0 minor API change
prevents replay across server boundaries. Existing initializer signatures remain
available; new configuration and session-start options use additional overloads.

MetricKit subscription and task state are owned by the main actor. Apple may call
`didReceive` from another executor, so that callback is explicitly nonisolated;
it snapshots diagnostic bytes before handing work to the main actor. Create,
start and stop collectors on the main actor. The API gate records these two
specific migration diagnostics only when comparing 0.5.0 with public 0.3.0;
other API regressions still fail.


### Coordinated release preparation

For a coordinated ecosystem release, keep the version-changing PR unmerged until
the final agreed Rails PR has been published and its deployment verified. Recheck
the upstream contract/workflow pin against that final backend commit before merge.
Successful source CI, a tag, or a release-impact dispatch alone is not backend readiness.
After independent review, merging the new version runs CI, creates an immutable tag,
and explicitly dispatches publication. A tag without a package remains incomplete.

To recover an existing reviewed tag, dispatch the publisher workflow from `main`
with `-f tag=vX.Y.Z` (Python uses `publish.yml`; other SDKs use `release.yml`). The
workflow checks out that exact tag, proves it belongs to main, and verifies public
package identity before creating the GitHub Release. Never move a consumed tag.

Weekly CI audits/tests current dependencies and cannot trigger automatic publication.
Dependabot groups compatible minor/patch updates; major toolchain migrations keep
separate PRs. Pin Actions to full commits and retain supported runtime floors.

## Request correlation (0.6.0+)

Use the opt-in URLSession wrapper for calls to your backend. Every attempt has
an immutable handle; unrelated tasks never share a global “last request”.

```swift
let http = LogisterHTTPClient(
    client: client,
    allowedOrigins: [URL(string: "https://api.example.test")!],
    excludedURLs: [URL(string: "https://api.example.test/mobile-token")!]
)
let result = try await http.data(for: URLRequest(url: URL(string: "https://api.example.test/orders")!))
if let response = result.response as? HTTPURLResponse, response.statusCode >= 500,
   let trace = result.traceContext {
    try await client.captureException(URLError(.badServerResponse), options: trace.eventOptions)
}
```

Transport failures throw `LogisterHTTPRequestError` with the underlying error and
optional `traceContext`. Attach that handle to the corresponding handled error.
The wrapper records HTTP spans, adopts valid existing outbound W3C headers, and
excludes the SDK's ingest endpoint. List token endpoints explicitly. Redirects
are returned as 3xx; call the wrapper again after checking the new destination,
passing `parent: result.traceContext` when it is a continuation. No global
URLSession instrumentation or automatic MetricKit/crash-to-request matching occurs.

A linked-project lookup also requires Logister 3.7+, the instance flag
`LOGISTER_CROSS_PROJECT_CORRELATIONS=true`, and explicit project/environment
connections under Settings → Integrations → Connected projects. Enable related
requests on both projects. A connection never grants project access.

Use the returned request handle when reporting a handled HTTP failure later.
Do not attach the most recent request to an unrelated crash or OS diagnostic.
Configure each app's own `release` and `environment`; mobile and backend releases
are independent. The backend shows exact identifier evidence and retention gaps.
See the [request correlation guide](https://logister.org/docs/request-correlation/).

### HTTP evidence (0.6.1+)

Traced HTTP spans include optional `context.http` fields: `method`,
`status_code` when a response is available, `failure_kind`, `attempt`, and
`duration_scope`. Failure categories distinguish HTTP 4xx/5xx responses from
transport failures such as timeout, DNS, connection, TLS or cancellation.
No request/response bodies or headers are added. Operation labels should be
static and exclude credentials or customer data. Older servers safely accept
this metadata; Logister 3.8 uses it in connected request and impact views.

URLSession `data(for:)` records `response_body` duration through receipt of the body. Each explicit wrapper call is attempt 1; retries are separate calls.

Client and backend durations measure different work. Do not subtract them to
estimate network time. A shared identifier establishes related evidence, not
root cause; omitted fields mean the evidence was not captured.
