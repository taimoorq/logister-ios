import Foundation
import XCTest
@testable import Logister

final class CapturingTransport: LogisterTransport {
    var request: URLRequest?
    var body: Data?
    var requests: [URLRequest] = []
    var sendCount = 0

    func send(request: URLRequest, body: Data) async throws -> LogisterResponse {
        sendCount += 1
        self.request = request
        requests.append(request)
        self.body = body
        return LogisterResponse(statusCode: 201)
    }

    func envelope() throws -> [String: Any] {
        let body = try XCTUnwrap(body)
        let object = try JSONSerialization.jsonObject(with: body)
        return try XCTUnwrap(object as? [String: Any])
    }
}

final class LogisterClientTests: XCTestCase {
    func testCaptureMetricEnvelope() async throws {
        let transport = CapturingTransport()
        let tokenProvider = SequenceTokenProvider(tokens: [
            LogisterToken(token: "mobile-token-1", expiresAt: Date().addingTimeInterval(300))
        ])
        let client = LogisterClient(
            baseURL: URL(string: "https://logister.example")!,
            tokenProvider: tokenProvider,
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

        XCTAssertTrue(response.accepted)
        XCTAssertEqual(transport.request?.value(forHTTPHeaderField: "Authorization"), "Bearer mobile-token-1")
        XCTAssertEqual(transport.request?.value(forHTTPHeaderField: "User-Agent"), "logister-ios/0.1.3")
        let fetchCount = await tokenProvider.fetchCount
        XCTAssertEqual(fetchCount, 1)

        let envelope = try transport.envelope()
        let event = try XCTUnwrap(envelope["event"] as? [String: Any])
        let context = try XCTUnwrap(event["context"] as? [String: Any])

        XCTAssertEqual(event["event_type"] as? String, "metric")
        XCTAssertEqual(event["message"] as? String, "cache.hit_rate")
        XCTAssertEqual(event["environment"] as? String, "production")
        XCTAssertEqual(event["release"] as? String, "1.0.0+42")
        XCTAssertEqual(context["platform"] as? String, "ios")
        XCTAssertEqual(context["service"] as? String, "com.example.app")
        XCTAssertEqual(context["repository"] as? String, "acme/ios")
        XCTAssertEqual(context["commit_sha"] as? String, "abc1234")
        XCTAssertEqual(context["branch"] as? String, "main")
        XCTAssertEqual(context["session_id"] as? String, "session-123")
        XCTAssertEqual(context["screen_name"] as? String, "Checkout")
        XCTAssertEqual(context["value"] as? Double, 0.98)
        XCTAssertEqual(context["unit"] as? String, "ratio")
    }

    func testCaptureSpanEnvelope() async throws {
        let transport = CapturingTransport()
        let client = LogisterClient(
            endpoint: URL(string: "https://logister.example/api/v1/ingest_events")!,
            tokenProvider: SequenceTokenProvider(tokens: [
                LogisterToken(token: "mobile-token-1", expiresAt: Date().addingTimeInterval(300))
            ]),
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

        let event = try XCTUnwrap(transport.envelope()["event"] as? [String: Any])
        let context = try XCTUnwrap(event["context"] as? [String: Any])

        XCTAssertEqual(event["event_type"] as? String, "span")
        XCTAssertEqual(event["trace_id"] as? String, "trace-123")
        XCTAssertEqual(event["span_id"] as? String, "span-456")
        XCTAssertEqual(event["parent_span_id"] as? String, "span-root")
        XCTAssertEqual(event["name"] as? String, "GET /checkout")
        XCTAssertEqual(event["kind"] as? String, "http")
        XCTAssertEqual(event["duration_ms"] as? Double, 42.5)
        XCTAssertEqual(context["platform"] as? String, "ios")
        XCTAssertEqual(context["screen_name"] as? String, "Checkout")
    }

    func testCaptureExceptionEnvelope() async throws {
        enum SampleError: Error {
            case failed
        }

        let transport = CapturingTransport()
        let client = LogisterClient(
            endpoint: URL(string: "https://logister.example/api/v1/ingest_events")!,
            tokenProvider: SequenceTokenProvider(tokens: [
                LogisterToken(token: "mobile-token-1", expiresAt: Date().addingTimeInterval(300))
            ]),
            transport: transport
        )

        try await client.captureException(SampleError.failed)

        let event = try XCTUnwrap(transport.envelope()["event"] as? [String: Any])
        let context = try XCTUnwrap(event["context"] as? [String: Any])
        let exception = try XCTUnwrap(context["exception"] as? [String: Any])
        let stacktrace = try XCTUnwrap(exception["stacktrace"] as? [String])

        XCTAssertEqual(event["event_type"] as? String, "error")
        XCTAssertEqual(event["level"] as? String, "error")
        XCTAssertNotNil(exception["type"] as? String)
        XCTAssertEqual(exception["message"] as? String, "failed")
        XCTAssertFalse(stacktrace.isEmpty)
    }

    func testTokenCaching() async throws {
        let transport = CapturingTransport()
        let tokenProvider = SequenceTokenProvider(tokens: [
            LogisterToken(token: "mobile-token-1", expiresAt: Date().addingTimeInterval(300))
        ])
        let client = LogisterClient(
            endpoint: URL(string: "https://logister.example/api/v1/ingest_events")!,
            tokenProvider: tokenProvider,
            transport: transport
        )

        try await client.captureMessage("one")
        try await client.captureMessage("two")

        let fetchCount = await tokenProvider.fetchCount
        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(
            transport.requests.map { $0.value(forHTTPHeaderField: "Authorization") },
            [ "Bearer mobile-token-1", "Bearer mobile-token-1" ]
        )
    }

    func testTokenRefresh() async throws {
        let transport = CapturingTransport()
        let tokenProvider = SequenceTokenProvider(tokens: [
            LogisterToken(token: "mobile-token-1", expiresAt: Date().addingTimeInterval(30)),
            LogisterToken(token: "mobile-token-2", expiresAt: Date().addingTimeInterval(300))
        ])
        let client = LogisterClient(
            endpoint: URL(string: "https://logister.example/api/v1/ingest_events")!,
            tokenProvider: tokenProvider,
            transport: transport
        )

        try await client.captureMessage("one")
        try await client.captureMessage("two")

        let fetchCount = await tokenProvider.fetchCount
        XCTAssertEqual(fetchCount, 2)
        XCTAssertEqual(
            transport.requests.map { $0.value(forHTTPHeaderField: "Authorization") },
            [ "Bearer mobile-token-1", "Bearer mobile-token-2" ]
        )
    }

    func testProviderFailureDoesNotSend() async throws {
        let transport = CapturingTransport()
        let client = LogisterClient(
            endpoint: URL(string: "https://logister.example/api/v1/ingest_events")!,
            tokenProvider: FailingTokenProvider(),
            transport: transport
        )

        do {
            try await client.captureMessage("one")
            XCTFail("Expected token provider failure")
        } catch {
            XCTAssertTrue(error is TokenProviderTestError)
        }

        XCTAssertEqual(transport.sendCount, 0)
    }

    func testBlankTokenDoesNotSend() async throws {
        let transport = CapturingTransport()
        let client = LogisterClient(
            endpoint: URL(string: "https://logister.example/api/v1/ingest_events")!,
            tokenProvider: SequenceTokenProvider(tokens: [
                LogisterToken(token: "", expiresAt: Date().addingTimeInterval(300))
            ]),
            transport: transport
        )

        do {
            try await client.captureMessage("one")
            XCTFail("Expected invalid mobile token failure")
        } catch {
            XCTAssertEqual(error as? LogisterError, .invalidMobileIngestToken)
        }

        XCTAssertEqual(transport.sendCount, 0)
    }

    func testExpiredTokenDoesNotSend() async throws {
        let transport = CapturingTransport()
        let client = LogisterClient(
            endpoint: URL(string: "https://logister.example/api/v1/ingest_events")!,
            tokenProvider: SequenceTokenProvider(tokens: [
                LogisterToken(token: "expired-token", expiresAt: Date().addingTimeInterval(-1))
            ]),
            transport: transport
        )

        do {
            try await client.captureMessage("one")
            XCTFail("Expected invalid mobile token failure")
        } catch {
            XCTAssertEqual(error as? LogisterError, .invalidMobileIngestToken)
        }

        XCTAssertEqual(transport.sendCount, 0)
    }
}

actor SequenceTokenProvider: LogisterTokenProvider {
    private var tokens: [LogisterToken]
    private(set) var fetchCount = 0

    init(tokens: [LogisterToken]) {
        self.tokens = tokens
    }

    func fetchToken() async throws -> LogisterToken {
        fetchCount += 1
        if tokens.count > 1 {
            return tokens.removeFirst()
        }
        return tokens[0]
    }
}

struct TokenProviderTestError: Error {
}

struct FailingTokenProvider: LogisterTokenProvider {
    func fetchToken() async throws -> LogisterToken {
        throw TokenProviderTestError()
    }
}
