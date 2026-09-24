import Foundation

/// An immutable identity for one HTTP attempt, safe to retain across tasks.
public struct LogisterTraceContext: Equatable, Sendable {
    public let traceID: String
    public let spanID: String
    public let parentSpanID: String?
    public let requestID: String
    public let flags: String

    public init(parent: LogisterTraceContext? = nil) {
        traceID = parent?.traceID ?? Self.randomHex(length: 32)
        spanID = Self.randomHex(length: 16)
        parentSpanID = parent?.spanID
        requestID = parent?.requestID ?? UUID().uuidString.lowercased()
        flags = parent?.flags ?? "01"
    }

    /// Adopts an existing outbound W3C version 00 header without replacing its span.
    public init?(traceparent: String, requestID: String? = nil) {
        let parts = traceparent.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, parts[0] == "00",
              Self.validHex(parts[1], length: 32), Self.validHex(parts[2], length: 16),
              Self.validHex(parts[3], length: 2, allowZero: true) else { return nil }
        self.traceID = parts[1]
        self.spanID = parts[2]
        self.parentSpanID = nil
        self.flags = parts[3]
        self.requestID = requestID.flatMap(Self.validRequestID) ?? UUID().uuidString.lowercased()
    }

    public var traceparent: String { "00-\(traceID)-\(spanID)-\(flags)" }
    public var context: LogisterContext {
        var context: LogisterContext = ["trace_id": .string(traceID), "span_id": .string(spanID), "request_id": .string(requestID)]
        if let parentSpanID { context["parent_span_id"] = .string(parentSpanID) }
        return context
    }
    public var eventOptions: LogisterEventOptions {
        LogisterEventOptions(traceID: traceID, requestID: requestID, context: context)
    }

    public func headers(for url: URL, allowedOrigins: [URL]) -> [String: String] {
        guard let origin = Self.origin(url), allowedOrigins.contains(where: { Self.origin($0) == origin }) else { return [:] }
        return ["traceparent": traceparent, "x-request-id": requestID]
    }

    static func origin(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), url.user == nil, url.password == nil else { return nil }
        return "\(scheme)://\(host):\(url.port ?? (scheme == "https" ? 443 : 80))"
    }
    private static func validRequestID(_ value: String) -> String? {
        guard (1...200).contains(value.utf8.count), value.range(of: "\\A[A-Za-z0-9._:-]+\\z", options: .regularExpression) != nil else { return nil }
        return value
    }
    private static func validHex(_ value: String, length: Int, allowZero: Bool = false) -> Bool {
        value.utf8.count == length && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } && (allowZero || value.contains { $0 != "0" })
    }
    private static func randomHex(length: Int) -> String {
        // SystemRandomNumberGenerator uses the platform's secure random source.
        (0..<(length / 2)).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}
