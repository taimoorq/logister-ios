import Foundation
import XCTest
@testable import Logister

private actor CorrelationTransport: LogisterTransport {
    var bodies: [Data] = []
    func send(request: URLRequest, body: Data) async throws -> LogisterResponse {
        bodies.append(body)
        return LogisterResponse(statusCode: 202)
    }
    func captured() -> [Data] { bodies }
}

private struct CorrelationToken: LogisterTokenProvider {
    func fetchToken() async throws -> LogisterToken { LogisterToken(token: "synthetic-mobile-token", expiresAt: Date().addingTimeInterval(300)) }
}

private final class CorrelationURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url?.path == "/offline" {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let body = try! JSONSerialization.data(withJSONObject: ["traceparent": request.value(forHTTPHeaderField: "traceparent") ?? ""])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: [:])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor final class LogisterHTTPClientTests: XCTestCase {
    func testRequestIdentityReachesTheWireAndCanBeAttachedToFailure() async throws {
        let transport = CorrelationTransport()
        let client = LogisterClient(baseURL: URL(string: "https://logister.example")!, tokenProvider: CorrelationToken(),
            environment: "production", release: "mobile-test", transport: transport)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CorrelationURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let http = LogisterHTTPClient(client: client, allowedOrigins: [URL(string: "https://api.example")!], session: session)
        let result = try await http.data(for: URLRequest(url: URL(string: "https://api.example/work")!))
        let trace = try XCTUnwrap(result.traceContext)
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: result.data) as? [String: String])
        XCTAssertEqual(wire["traceparent"], trace.traceparent)
        try await client.captureException(URLError(.badServerResponse), options: trace.eventOptions)
        for _ in 0..<100 {
            if await transport.captured().count >= 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let bodies = await transport.captured()
        XCTAssertEqual(bodies.count, 2)
        let events = try bodies.map { try JSONSerialization.jsonObject(with: $0) as! [String: Any] }
        for envelope in events {
            let context = (envelope["event"] as! [String: Any])["context"] as! [String: Any]
            XCTAssertEqual(context["trace_id"] as? String, trace.traceID)
            XCTAssertEqual(context["span_id"] as? String, trace.spanID)
        }
        if let directory = ProcessInfo.processInfo.environment["LOGISTER_CORRELATION_FIXTURES"] {
            let fixture: [String: Any] = ["headers": ["traceparent": trace.traceparent, "x-request-id": trace.requestID], "envelopes": events]
            try JSONSerialization.data(withJSONObject: fixture, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: directory).appendingPathComponent("ios.json"))
        }
        do {
            _ = try await http.data(for: URLRequest(url: URL(string: "https://api.example/offline")!))
            XCTFail("Expected network failure")
        } catch let failure as LogisterHTTPRequestError {
            XCTAssertNotNil(failure.traceContext)
            XCTAssertNotEqual(failure.traceContext?.spanID, trace.spanID)
        }
        let unrelated = try await http.data(for: URLRequest(url: URL(string: "https://other.example/work")!))
        XCTAssertNil(unrelated.traceContext)
    }
}
