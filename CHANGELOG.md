# Changelog

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
