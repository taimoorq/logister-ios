# Changelog

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
