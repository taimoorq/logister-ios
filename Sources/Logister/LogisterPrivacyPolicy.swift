import Foundation

/// Controls how much error detail the SDK serializes.
public enum LogisterExceptionDataPolicy: String, Equatable, Sendable {
    /// Sends the exception type and bounded stack frames without messages,
    /// causes, NSError domains, or NSError codes.
    case typeAndStacktrace = "type_and_stacktrace"

    /// Preserves the 0.2.x manual-capture behavior for applications that have
    /// explicitly reviewed raw error text and NSError metadata.
    case full
}

/// Controls inferred Apple device context. Apps with a strict data-minimization
/// contract can omit the exact model, locale, architecture, and OS build while
/// retaining the device family and OS version needed for compatibility triage.
public enum LogisterPlatformContextPolicy: String, Equatable, Sendable {
    case standard
    case minimized
}
