import Foundation
import Testing
@testable import Logister

final class CapturingTransport: LogisterTransport {
    var request: URLRequest?
    var body: Data?

    func send(request: URLRequest, body: Data) async throws -> LogisterResponse {
        self.request = request
        self.body = body
        return LogisterResponse(statusCode: 201)
    }

    func envelope() throws -> [String: Any] {
        let body = try #require(body)
        let object = try JSONSerialization.jsonObject(with: body)
        return try #require(object as? [String: Any])
    }
}

@Suite("LogisterClient")
struct LogisterClientTests {
    @Test("captureMetric sends Logister metric envelope")
    func captureMetricEnvelope() async throws {
        let transport = CapturingTransport()
        let client = LogisterClient(
            apiKey: "test-token",
            baseURL: URL(string: "https://logister.example")!,
            environment: "production",
            release: "1.0.0+42",
            repository: "acme/ios",
            commitSHA: "abc1234",
            branch: "main",
            service: "com.example.app",
            transport: transport
        )

        let response = try await client.captureMetric(
            "cache.hit_rate",
            value: 0.98,
            unit: "ratio",
            options: LogisterEventOptions(sessionID: "session-123", context: ["screen_name": .string("Checkout")])
        )

        #expect(response.accepted)
        #expect(transport.request?.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")

        let envelope = try transport.envelope()
        let event = try #require(envelope["event"] as? [String: Any])
        let context = try #require(event["context"] as? [String: Any])

        #expect(event["event_type"] as? String == "metric")
        #expect(event["message"] as? String == "cache.hit_rate")
        #expect(event["environment"] as? String == "production")
        #expect(event["release"] as? String == "1.0.0+42")
        #expect(context["platform"] as? String == "ios")
        #expect(context["service"] as? String == "com.example.app")
        #expect(context["repository"] as? String == "acme/ios")
        #expect(context["commit_sha"] as? String == "abc1234")
        #expect(context["branch"] as? String == "main")
        #expect(context["session_id"] as? String == "session-123")
        #expect(context["screen_name"] as? String == "Checkout")
        #expect(context["value"] as? Double == 0.98)
        #expect(context["unit"] as? String == "ratio")
    }

    @Test("captureSpan sends span payload fields")
    func captureSpanEnvelope() async throws {
        let transport = CapturingTransport()
        let client = LogisterClient(
            apiKey: "test-token",
            endpoint: URL(string: "https://logister.example/api/v1/ingest_events")!,
            transport: transport
        )

        let span = LogisterSpan(
            traceID: "trace-123",
            spanID: "span-456",
            parentSpanID: "span-root",
            name: "GET /checkout",
            kind: "http",
            status: "ok",
            durationMs: 42.5,
            context: ["screen_name": .string("Checkout")]
        )

        try await client.captureSpan(span)

        let event = try #require(transport.envelope()["event"] as? [String: Any])
        let context = try #require(event["context"] as? [String: Any])

        #expect(event["event_type"] as? String == "span")
        #expect(event["trace_id"] as? String == "trace-123")
        #expect(event["span_id"] as? String == "span-456")
        #expect(event["parent_span_id"] as? String == "span-root")
        #expect(event["name"] as? String == "GET /checkout")
        #expect(event["kind"] as? String == "http")
        #expect(event["duration_ms"] as? Double == 42.5)
        #expect(context["platform"] as? String == "ios")
        #expect(context["screen_name"] as? String == "Checkout")
    }

    @Test("captureException includes structured exception context")
    func captureExceptionEnvelope() async throws {
        enum SampleError: Error {
            case failed
        }

        let transport = CapturingTransport()
        let client = LogisterClient(
            apiKey: "test-token",
            endpoint: URL(string: "https://logister.example/api/v1/ingest_events")!,
            transport: transport
        )

        try await client.captureException(SampleError.failed)

        let event = try #require(transport.envelope()["event"] as? [String: Any])
        let context = try #require(event["context"] as? [String: Any])
        let exception = try #require(context["exception"] as? [String: Any])
        let stacktrace = try #require(exception["stacktrace"] as? [String])

        #expect(event["event_type"] as? String == "error")
        #expect(event["level"] as? String == "error")
        #expect(exception["type"] as? String != nil)
        #expect(exception["message"] as? String == "failed")
        #expect(!stacktrace.isEmpty)
    }
}
