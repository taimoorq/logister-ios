import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct LogisterHTTPResult: Sendable {
    public let data: Data
    public let response: URLResponse
    public let traceContext: LogisterTraceContext?
}

public struct LogisterHTTPRequestError: Error {
    public let underlying: any Error
    public let traceContext: LogisterTraceContext?
}

/// Opt-in application HTTP instrumentation. Redirects are returned to the caller
/// as 3xx responses so trace headers cannot escape the configured origin allowlist.
public struct LogisterHTTPClient: Sendable {
    private let client: LogisterClient
    private let session: URLSession
    private let allowedOrigins: [URL]
    private let excludedURLs: [URL]

    public init(client: LogisterClient, allowedOrigins: [URL], excludedURLs: [URL] = [], session: URLSession = .shared) {
        self.client = client
        self.allowedOrigins = allowedOrigins
        self.excludedURLs = excludedURLs + [client.endpoint]
        self.session = session
    }

    public func data(for original: URLRequest, operation: String = "HTTP request", parent: LogisterTraceContext? = nil) async throws -> LogisterHTTPResult {
        var request = original
        var trace: LogisterTraceContext?
        if let url = request.url, !excludedURLs.contains(where: { LogisterTraceContext.origin($0) == LogisterTraceContext.origin(url) && $0.path == url.path }),
           LogisterTraceContext.origin(url) != nil {
            let candidate = request.value(forHTTPHeaderField: "traceparent").flatMap {
                LogisterTraceContext(traceparent: $0, requestID: request.value(forHTTPHeaderField: "x-request-id"))
            } ?? LogisterTraceContext(parent: parent)
            let headers = candidate.headers(for: url, allowedOrigins: allowedOrigins)
            if !headers.isEmpty {
                trace = candidate
                headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            }
        }
        if trace == nil {
            ["traceparent", "tracestate", "x-request-id"].forEach { request.setValue(nil, forHTTPHeaderField: $0) }
        }
        let startedAt = Date()
        let start = ProcessInfo.processInfo.systemUptime
        do {
            let (data, response) = try await session.data(for: request, delegate: NoLogisterRedirects())
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            record(trace, operation: operation, method: request.httpMethod ?? "GET", statusCode: statusCode, failureKind: (statusCode ?? 0) >= 400 ? "http" : nil, startedAt: startedAt, elapsed: ProcessInfo.processInfo.systemUptime - start, failed: (statusCode ?? 0) >= 500)
            return LogisterHTTPResult(data: data, response: response, traceContext: trace)
        } catch {
            record(trace, operation: operation, method: request.httpMethod ?? "GET", statusCode: nil, failureKind: failureKind(error), startedAt: startedAt, elapsed: ProcessInfo.processInfo.systemUptime - start, failed: true)
            throw LogisterHTTPRequestError(underlying: error, traceContext: trace)
        }
    }

    private func failureKind(_ error: any Error) -> String {
        guard let error = error as? URLError else { return "transport" }
        switch error.code {
        case .timedOut: return "timeout"
        case .cannotFindHost, .dnsLookupFailed: return "dns"
        case .cancelled: return "cancelled"
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost: return "connection"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired: return "tls"
        default: return "transport"
        }
    }

    private func record(_ trace: LogisterTraceContext?, operation: String, method: String, statusCode: Int?, failureKind: String?, startedAt: Date, elapsed: TimeInterval, failed: Bool) {
        guard let trace else { return }
        let duration = elapsed * 1_000
        var metadata: LogisterContext = ["method": .string(String(method.uppercased().prefix(16))), "attempt": .number(1), "duration_scope": .string("response_body")]
        if let statusCode { metadata["status_code"] = .number(Double(statusCode)) }
        if let failureKind { metadata["failure_kind"] = .string(failureKind) }
        var context = trace.context
        context["http"] = .object(metadata)
        let span = LogisterSpan(traceID: trace.traceID, spanID: trace.spanID, parentSpanID: trace.parentSpanID,
            name: String(operation.prefix(200)), kind: "http", status: failed ? "error" : "ok", durationMs: max(0, duration), startedAt: startedAt,
            context: context)
        // Export cannot replace an application response or exception.
        Task { _ = try? await client.captureSpan(span, options: trace.eventOptions) }
    }
}

private final class NoLogisterRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
