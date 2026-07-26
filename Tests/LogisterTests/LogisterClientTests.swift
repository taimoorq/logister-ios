import Foundation
import XCTest
@testable import Logister

final class CapturingTransport: LogisterTransport, @unchecked Sendable {
    var request: URLRequest?
    var body: Data?
    var requests: [URLRequest] = []
    var sendCount = 0
    var responses: [LogisterResponse]

    init(responses: [LogisterResponse] = [LogisterResponse(statusCode: 201)]) {
        self.responses = responses
    }

    func send(request: URLRequest, body: Data) async throws -> LogisterResponse {
        sendCount += 1
        self.request = request
        requests.append(request)
        self.body = body
        if responses.count > 1 {
            return responses.removeFirst()
        }
        return responses[0]
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
        XCTAssertEqual(transport.request?.value(forHTTPHeaderField: "User-Agent"), "logister-ios/0.2.0")
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
        XCTAssertEqual(context["telemetry_schema_version"] as? Double, 2)
        XCTAssertNotNil(context["apple_platform"] as? String)
        XCTAssertNotNil(context["app"] as? [String: Any])
        XCTAssertNotNil(context["device"] as? [String: Any])
        XCTAssertNotNil(context["os"] as? [String: Any])
        XCTAssertEqual((context["sdk"] as? [String: Any])?["name"] as? String, "logister-ios")
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
        let stacktrace = try XCTUnwrap(exception["stacktrace"] as? [[String: Any]])
        let errorContext = try XCTUnwrap(context["error"] as? [String: Any])
        let diagnostic = try XCTUnwrap(context["diagnostic"] as? [String: Any])
        let threads = try XCTUnwrap(exception["threads"] as? [[String: Any]])

        XCTAssertEqual(event["event_type"] as? String, "error")
        XCTAssertEqual(event["level"] as? String, "error")
        XCTAssertNotNil(exception["type"] as? String)
        XCTAssertEqual(exception["message"] as? String, "failed")
        XCTAssertFalse(stacktrace.isEmpty)
        XCTAssertNotNil(stacktrace.first?["raw"] as? String)
        XCTAssertEqual(errorContext["mechanism"] as? String, "handled_exception")
        XCTAssertEqual(errorContext["handled"] as? Bool, true)
        XCTAssertEqual(errorContext["fatal"] as? Bool, false)
        XCTAssertEqual(diagnostic["source"] as? String, "sdk")
        XCTAssertEqual(diagnostic["kind"] as? String, "reported_error")
        XCTAssertEqual(threads.first?["triggered"] as? Bool, true)
    }

    func testCaptureAddsBoundedCorrelationBreadcrumbsAndRemovesSensitiveIdentifiers() async throws {
        let transport = CapturingTransport()
        let client = LogisterClient(
            endpoint: URL(string: "https://logister.example/api/v1/ingest_events")!,
            tokenProvider: SequenceTokenProvider(tokens: [
                LogisterToken(token: "mobile-token-1", expiresAt: Date().addingTimeInterval(300))
            ]),
            defaultContext: [
                "idfv": .string("must-not-leave-device"),
                "nested": .object([
                    "advertising_identifier": .string("also-private"),
                    "identifier-For-Vendor": .string("also-private-camel")
                ]),
                "app": .object(["screen": .string("Checkout")])
            ],
            transport: transport
        )
        let breadcrumbs = (0..<105).map {
            LogisterBreadcrumb(message: "step-\($0)")
        }

        try await client.captureException(
            NSError(domain: "Checkout", code: 42),
            options: LogisterEventOptions(
                sessionID: "session-123",
                installationIDHash: "rotating-hash",
                distributionChannel: "testflight",
                inForeground: true,
                breadcrumbs: breadcrumbs
            )
        )

        let event = try XCTUnwrap(transport.envelope()["event"] as? [String: Any])
        let context = try XCTUnwrap(event["context"] as? [String: Any])
        let app = try XCTUnwrap(context["app"] as? [String: Any])

        XCTAssertNil(context["idfv"])
        XCTAssertNil((context["nested"] as? [String: Any])?["advertising_identifier"])
        XCTAssertNil((context["nested"] as? [String: Any])?["identifier-For-Vendor"])
        XCTAssertEqual((context["session"] as? [String: Any])?["id"] as? String, "session-123")
        XCTAssertEqual((context["installation"] as? [String: Any])?["id_hash"] as? String, "rotating-hash")
        XCTAssertEqual((context["distribution"] as? [String: Any])?["channel"] as? String, "testflight")
        XCTAssertEqual(app["in_foreground"] as? Bool, true)
        XCTAssertEqual(app["screen"] as? String, "Checkout")
        XCTAssertEqual((context["breadcrumbs"] as? [[String: Any]])?.count, LogisterBreadcrumb.maximumPerEvent)
        XCTAssertEqual((context["breadcrumbs"] as? [[String: Any]])?.first?["message"] as? String, "step-5")
    }

    func testMetricKitDiagnosticNormalizesThreadsProvenanceAndStableUUIDSignature() async throws {
        let transport = CapturingTransport()
        let client = LogisterClient(
            endpoint: URL(string: "https://logister.example/api/v1/ingest_events")!,
            tokenProvider: SequenceTokenProvider(tokens: [
                LogisterToken(token: "mobile-token-1", expiresAt: Date().addingTimeInterval(300))
            ]),
            transport: transport
        )
        let payload: [String: Any] = [
            "exceptionType": 1,
            "exceptionCode": 2,
            "callStackTree": [
                "callStackPerThread": true,
                "callStacks": [[
                    "threadAttributed": true,
                    "callStackRootFrames": [[
                        "binaryName": ProcessInfo.processInfo.processName,
                        "binaryUUID": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
                        "address": 4_294_967_296,
                        "offsetIntoBinaryTextSegment": 4_672,
                        "subFrames": [[
                            "binaryName": "UIKitCore",
                            "binaryUUID": "FFFFFFFF-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
                            "address": 8_589_934_592,
                            "offsetIntoBinaryTextSegment": 40
                        ]]
                    ]]
                ]]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])

        try await client.captureMetricKitDiagnostic(data, kind: .crash)

        let event = try XCTUnwrap(transport.envelope()["event"] as? [String: Any])
        let context = try XCTUnwrap(event["context"] as? [String: Any])
        let diagnostic = try XCTUnwrap(context["diagnostic"] as? [String: Any])
        let error = try XCTUnwrap(context["error"] as? [String: Any])
        let exception = try XCTUnwrap(context["exception"] as? [String: Any])
        let threads = try XCTUnwrap(exception["threads"] as? [[String: Any]])
        let frames = try XCTUnwrap(threads.first?["frames"] as? [[String: Any]])

        XCTAssertEqual(diagnostic["source"] as? String, "metrickit")
        XCTAssertEqual(diagnostic["kind"] as? String, "crash")
        XCTAssertEqual(diagnostic["signature"] as? String, "metrickit:crash:AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE:4672.0")
        XCTAssertNotNil(diagnostic["external_id"] as? String)
        XCTAssertEqual(
            event["uuid"] as? String,
            LogisterMetricKitAdapter.eventID(from: data).uuidString.lowercased()
        )
        XCTAssertEqual(error["mechanism"] as? String, "native_crash")
        XCTAssertEqual(error["fatal"] as? Bool, true)
        XCTAssertEqual(threads.first?["triggered"] as? Bool, true)
        XCTAssertEqual(frames.first?["image_uuid"] as? String, "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        XCTAssertEqual((context["symbolication"] as? [String: Any])?["status"] as? String, "missing")
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

    func testCaptureRetriesOnlyTransientResponsesAndHonorsTheAttemptBound() async throws {
        let transport = CapturingTransport(responses: [
            LogisterResponse(statusCode: 429, headers: ["Retry-After": "0"]),
            LogisterResponse(statusCode: 503),
            LogisterResponse(statusCode: 201)
        ])
        let client = LogisterClient(
            endpoint: URL(string: "https://logister.example/api/v1/ingest_events")!,
            tokenProvider: SequenceTokenProvider(tokens: [
                LogisterToken(token: "mobile-token-1", expiresAt: Date().addingTimeInterval(300))
            ]),
            retryPolicy: LogisterRetryPolicy(maximumAttempts: 3, baseDelay: 0, maximumDelay: 0),
            transport: transport
        )

        let response = try await client.captureMessage("retry me")

        XCTAssertTrue(response.accepted)
        XCTAssertEqual(transport.sendCount, 3)
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
