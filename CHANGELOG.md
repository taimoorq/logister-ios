# Changelog

## v0.5.0 - 2026-08-09

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
