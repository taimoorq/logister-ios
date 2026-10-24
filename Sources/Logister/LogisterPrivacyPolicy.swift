import Foundation

/// Controls how much error detail the SDK serializes.
public enum LogisterExceptionDataPolicy: String, Equatable, Sendable {
    /// Sends the exception type and bounded stack frames without messages,
    /// causes, NSError domains, or NSError codes.
    case typeAndStacktrace = "type_and_stacktrace"

    /// Adds the error's `localizedDescription`, NSError domain and code, and
    /// a bounded reviewed `userInfo` subset (failure reason, recovery
    /// suggestion, failing URL without its query, and underlying domains and
    /// codes). Use it only after reviewing that text for the app's data policy.
    case full
}

/// Controls inferred Apple device context. Apps with a strict data-minimization
/// contract can omit the exact model, locale, architecture, and OS build while
/// retaining the device family and OS version needed for compatibility triage.
public enum LogisterPlatformContextPolicy: String, Equatable, Sendable {
    case standard
    case minimized
}
