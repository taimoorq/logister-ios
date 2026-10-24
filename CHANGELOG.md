# Changelog

## v0.7.0 - 2026-10-23

Security and reliability hardening. Several defaults change; see "Upgrading
to 0.7.0" in the README.

- Fixed MetricKit crash reports being rejected before delivery. One item
  budget was spent over alphabetically sorted keys, so a large context used it
  up before `event_type`, `message` and `uuid`. Envelope fields are now always
  kept, context has its own budget, the whole event stays within the server's
  512-key and 1,000,000-byte limits, and anything dropped sets
  `context._truncated`. Oversized events are shrunk instead of rejected.
- MetricKit crashes read Apple's `diagnosticMetaData` block, send the crashed
  thread first, and no longer repeat the linear crash call tree or copy the raw
  diagnostic into `source_evidence`. In safe mode that raw copy could include
  termination and Objective-C exception reason text.
- MetricKit numeric codes and sample counts of 0 or 1 are sent as numbers, not
  booleans.
- NaN and infinite numbers are sent as `null`. They previously raised an
  Objective-C exception that crashed the host app.
- Sensitive keys follow the shared Logister redaction rule. `accessToken`,
  `apiKey`, `x-api-key`, `refreshToken`, `clientSecret`, `idToken` and any key
  containing token, secret, password, passwd, apikey, authorization,
  credential or cookie are redacted. Their values become `"[REDACTED]"`
  instead of the key being removed. Strings are scrubbed for Bearer and Basic
  credentials, JWTs and `lgst_` keys, and URLs lose userinfo as well as query
  and fragment.
- The `.full` exception policy sends `localizedDescription`, the NSError domain
  and code, and a reviewed `userInfo` subset instead of
  `String(describing:)`. Initializers that do not name a policy, including the
  deprecated ones, now use `.typeAndStacktrace`.
- The default transport uses a dedicated ephemeral `URLSession` with 15 s
  request and 60 s resource timeouts, no cookies or cache, and no redirects.
- Endpoints must use https unless the host is loopback or
  `LogisterConfiguration.allowsInsecureTransport` is set.
- Token provider calls time out after `tokenProviderTimeout` (30 s), and
  invalidating a token no longer cancels a refresh other callers share.
- A 401 that persists after the one token refresh keeps the event queued, as
  documented, instead of discarding it.
- Computed retry delays are jittered.
- The durable queue writes one file per event instead of rewriting the whole
  queue on every change. The previous queue file is migrated on first launch.
- Internal payload failures return a dropped response instead of throwing.

## v0.6.1 - 2026-09-28

- Record optional HTTP method, status code, failure category, attempt number and duration scope on traced calls for connected-project investigation.
- Preserve application results, origin allowlists, request handles and compatibility with older Logister servers.

## v0.6.0 - 2026-09-24

- Add immutable W3C request handles and an opt-in URLSession wrapper with exact-origin allowlists.
- Attach request identity to handled errors and HTTP spans; return redirects without forwarding trace headers and exclude telemetry endpoints.

## v0.5.0 - 2026-09-11

- Kept internal beforeSend discard signaling private and restored the initializer symbols from 0.3.0.
- Documented the deliberate pre-1.0 migration to immutable endpoints and main-actor MetricKit lifecycle, with a narrowly scoped API diagnostic allowlist.
- Restored explicit release dispatch, exact-tag recovery, and weekly verification without scheduled publication.

- Normalized MetricKit diagnostics as crash, hang, excessive CPU, excessive disk writes, and slow launch instead of forcing resource and performance evidence through exception semantics.
- Added bounded hierarchical call-stack trees with attributed/sample roles and sample counts while retaining the flattened compatibility view.
- Added canonical seconds/bytes measurements for hang duration, CPU time, sampled time, disk writes, and launch duration.
- Preserved addresses and binary-relative offsets as lossless hexadecimal strings and added stable signatures for attributed sampled paths.
- Stopped inferring fatality or user impact when Apple evidence does not provide it, and added iOS 16+ slow-launch collection to the MetricKit subscriber.
- Added explicit session-start timing for trustworthy early-session analysis when session correlation is enabled.

## v0.4.0 - 2026-08-09

- Added telemetry schema v3 evidence with SDK-owned stable UUIDs, exact capture times, and producer metadata.
- Added source reporting intervals for MetricKit diagnostics while omitting misleading point-in-time occurrence timestamps.
- Preserved MetricKit source, kind, capture mode, and stable retry identity in the additive evidence envelope.
- Added an actor-owned, endpoint/app/client/process-scoped durable queue in Application Support, excluded it from backup, persisted before authentication, and added relaunch replay, local dedupe, bounded retention/backpressure, retry scheduling, one-time `401` refresh, and permanent-response discard.
- Added runtime collection disable/purge, an opt-in rotating delivery-installation pseudonym, recursive credential/URL scrubbing, payload budgets, an immutable final `beforeSend` hook, and bounded client health.
- Preserved MetricKit payload reporting boundaries, source app build/device/OS/TestFlight metadata, and privacy-filtered immutable source evidence without copying uploader-time app/device/release facts.
- Made MetricKit subscription and upload-task lifecycle main-actor owned and bundled a privacy manifest that declares diagnostic, usage, optional identifier, and custom-data capabilities with no tracking domains or required-reason APIs.

## v0.3.0 - 2026-07-29

- Added explicit full and type-and-stacktrace exception data policies. The safe
  policy omits error messages, NSError domains/codes, and other raw error text.
- Made MetricKit collection use the safe policy by default, with bounded
  threads/frames and without the raw diagnostic payload or termination reason.
- Added a minimized Apple platform-context policy that omits exact model,
  locale, architecture, and OS build for apps with stricter privacy contracts.
- Labeled manual and MetricKit errors with stable capture-source and data-policy
  metadata so Logister can distinguish redacted reports in the inbox.

## v0.2.0 - 2026-07-26

- Added the versioned Apple telemetry contract with automatic bundle,
  version/build, Apple-platform, OS/build, device, architecture, locale, SDK,
  and inferred-release context.
- Marked manual exception capture as a handled reported error and added
  structured threads/frames, bounded breadcrumbs, distribution and foreground
  state, and opt-in session and rotating installation correlation.
- Added the opt-in MetricKit collector for crash, hang, CPU-exception, and
  disk-write diagnostics, with privacy filtering and deterministic event IDs
  for idempotent server redelivery.
- Added bounded transient retries for network errors, HTTP 408/425/429, and 5xx
  responses, including capped `Retry-After` handling.
- Removed common IDFA, IDFV, serial, and hardware-identifier aliases recursively
  before telemetry leaves the app.
