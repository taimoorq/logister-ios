import Foundation
import XCTest
@testable import Logister

final class CapturingTransport: LogisterTransport, @unchecked Sendable {
    var request: URLRequest?
    var body: Data?
    var bodies: [Data] = []
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
        bodies.append(body)
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
            configuration: testConfiguration(),
            transport: transport
        )

        let response = try await client.captureMetric(
            "cache.hit_rate",
            value: 0.98,
            unit: "ratio",
            options: LogisterEventOptions(
                sessionID: "session-123",
                sessionStartedAt: Date(timeIntervalSince1970: 0),
                context: ["screen_name": .string("Checkout")]
            )
        )

        XCTAssertTrue(response.accepted)
        XCTAssertEqual(transport.request?.value(forHTTPHeaderField: "Authorization"), "Bearer mobile-token-1")
        XCTAssertEqual(transport.request?.value(forHTTPHeaderField: "User-Agent"), "logister-ios/0.5.0")
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
        XCTAssertEqual(context["telemetry_schema_version"] as? Double, 3)
        XCTAssertNotNil(event["uuid"] as? String)
        XCTAssertNotNil(event["occurred_at"] as? String)
        XCTAssertEqual((event["evidence"] as? [String: Any])?["source"] as? String, "sdk")
        XCTAssertEqual((event["evidence"] as? [String: Any])?["identity_scope"] as? String, "occurrence")
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
        XCTAssertEqual((context["session"] as? [String: Any])?["started_at"] as? String, "1970-01-01T00:00:00.000Z")
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
            configuration: testConfiguration(),
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
            configuration: testConfiguration(),
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
        XCTAssertEqual(errorContext["capture_source"] as? String, "manual")
        XCTAssertEqual(errorContext["data_policy"] as? String, "full")
        XCTAssertEqual(diagnostic["source"] as? String, "sdk")
        XCTAssertEqual(diagnostic["kind"] as? String, "reported_error")
        XCTAssertEqual(threads.first?["triggered"] as? Bool, false)
        XCTAssertEqual(threads.first?["role"] as? String, "reporting")
        XCTAssertEqual(errorContext["thread_role"] as? String, "reporting")
    }

    func testSafeExceptionPolicyOmitsRawErrorTextAndMetadata() async throws {
        let transport = CapturingTransport()
        let client = LogisterClient(
            endpoint: URL(string: "https://logister.example/api/v1/ingest_events")!,
            tokenProvider: SequenceTokenProvider(tokens: [
                LogisterToken(token: "mobile-token-1", expiresAt: Date().addingTimeInterval(300))
            ]),
            exceptionDataPolicy: .typeAndStacktrace,
            platformContextPolicy: .minimized,
            configuration: testConfiguration(),
            transport: transport
        )
        let secret = "Bearer private-token-value"

        try await client.captureException(
            NSError(
                domain: "private.account.domain",
                code: 42,
                userInfo: [NSLocalizedDescriptionKey: secret]
            )
        )

        let envelope = try transport.envelope()
        let serialized = String(
            data: try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]),
            encoding: .utf8
        )!
        let event = try XCTUnwrap(envelope["event"] as? [String: Any])
        let context = try XCTUnwrap(event["context"] as? [String: Any])
        let exception = try XCTUnwrap(context["exception"] as? [String: Any])
        let errorContext = try XCTUnwrap(context["error"] as? [String: Any])
        let device = try XCTUnwrap(context["device"] as? [String: Any])
        let os = try XCTUnwrap(context["os"] as? [String: Any])

        XCTAssertFalse(serialized.contains(secret))
        XCTAssertFalse(serialized.contains("private.account.domain"))
        XCTAssertNil(exception["message"])
        XCTAssertNil(exception["domain"])
        XCTAssertNil(exception["code"])
        XCTAssertNotNil(exception["type"])
        XCTAssertNotNil(exception["stacktrace"])
        XCTAssertEqual(errorContext["data_policy"] as? String, "type_and_stacktrace")
        XCTAssertNil(device["model"])
        XCTAssertNil(device["locale"])
        XCTAssertNil(device["architecture"])
        XCTAssertNil(os["build"])
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
            configuration: testConfiguration(),
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
            configuration: testConfiguration(),
            transport: transport
        )
        let payload: [String: Any] = [
            "timeStampBegin": "2026-08-01T00:00:00Z",
            "timeStampEnd": "2026-08-02T00:00:00Z",
            "exceptionType": 1,
            "exceptionCode": 2,
            "terminationReason": "private diagnostic detail",
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
        let evidence = try XCTUnwrap(event["evidence"] as? [String: Any])
        let diagnostic = try XCTUnwrap(context["diagnostic"] as? [String: Any])
        let error = try XCTUnwrap(context["error"] as? [String: Any])
        let exception = try XCTUnwrap(context["exception"] as? [String: Any])
        let threads = try XCTUnwrap(exception["threads"] as? [[String: Any]])
        let frames = try XCTUnwrap(threads.first?["frames"] as? [[String: Any]])

        XCTAssertEqual(diagnostic["source"] as? String, "metrickit")
        XCTAssertEqual(diagnostic["kind"] as? String, "crash")
        XCTAssertEqual(diagnostic["signature"] as? String, "metrickit:crash:AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE:0x1240")
        XCTAssertNotNil(diagnostic["external_id"] as? String)
        XCTAssertEqual(
            event["uuid"] as? String,
            LogisterMetricKitAdapter.eventID(from: data).uuidString.lowercased()
        )
        XCTAssertEqual(error["mechanism"] as? String, "native_crash")
        XCTAssertEqual(error["fatal"] as? Bool, true)
        XCTAssertNil(error["user_perceived"])
        XCTAssertEqual(error["capture_source"] as? String, "metrickit")
        XCTAssertEqual(error["data_policy"] as? String, "type_and_stacktrace")
        XCTAssertEqual(threads.first?["triggered"] as? Bool, true)
        XCTAssertEqual(frames.first?["image_uuid"] as? String, "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        XCTAssertEqual(frames.first?["address"] as? String, "0x100000000")
        XCTAssertEqual(frames.first?["relative_address"] as? String, "0x1240")
        let callTree = try XCTUnwrap(diagnostic["call_stack_tree"] as? [String: Any])
        let stacks = try XCTUnwrap(callTree["stacks"] as? [[String: Any]])
        let roots = try XCTUnwrap(stacks.first?["root_frames"] as? [[String: Any]])
        XCTAssertEqual(callTree["per_thread"] as? Bool, true)
        XCTAssertEqual(stacks.first?["role"] as? String, "crashed")
        XCTAssertEqual(roots.first?["relative_address"] as? String, "0x1240")
        XCTAssertEqual((roots.first?["subframes"] as? [[String: Any]])?.first?["relative_address"] as? String, "0x28")
        XCTAssertNil(context["symbolication"])
        XCTAssertEqual((diagnostic["binary_uuids"] as? [String])?.first, "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        XCTAssertNil((context["termination"] as? [String: Any])?["reason"])
        XCTAssertNil(context["metrickit"])
        XCTAssertNil(event["occurred_at"])
        XCTAssertEqual(evidence["source"] as? String, "metrickit")
        XCTAssertEqual(evidence["kind"] as? String, "crash")
        XCTAssertEqual(evidence["capture_mode"] as? String, "metrickit_payload")
        XCTAssertEqual((evidence["reporting_period"] as? [String: Any])?["start"] as? String, "2026-08-01T00:00:00Z")
        XCTAssertEqual((evidence["producer"] as? [String: Any])?["sdk_version"] as? String, "0.5.0")
    }

    func testMetricKitResourceDiagnosticUsesTypedMeasurementsAndSampledTreeWithoutAnException() async throws {
        let transport = CapturingTransport()
        let client = LogisterClient(
            endpoint: URL(string: "https://logister.example/api/v1/ingest_events")!,
            tokenProvider: SequenceTokenProvider(tokens: [
                LogisterToken(token: "mobile-token-1", expiresAt: Date().addingTimeInterval(300))
            ]),
            configuration: testConfiguration(),
            transport: transport
        )
        let payload: [String: Any] = [
            "totalCPUTime": "98 sec",
            "totalSampledTime": ["value": 60, "unit": "seconds"],
            "callStackTree": [
                "callStackPerThread": false,
                "callStacks": [[
                    "threadAttributed": true,
                    "sampleCount": 12,
                    "callStackRootFrames": [[
                        "binaryName": ProcessInfo.processInfo.processName,
                        "binaryUUID": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
                        "address": 4_294_967_296,
                        "offsetIntoBinaryTextSegment": 4_672,
                        "sampleCount": 9
                    ]]
                ]]
            ]
        ]

        try await client.captureMetricKitDiagnostic(
            JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            kind: .cpuException
        )

        let event = try XCTUnwrap(transport.envelope()["event"] as? [String: Any])
        let context = try XCTUnwrap(event["context"] as? [String: Any])
        let diagnostic = try XCTUnwrap(context["diagnostic"] as? [String: Any])
        let measurements = try XCTUnwrap(diagnostic["measurements"] as? [String: Any])
        let cpu = try XCTUnwrap(measurements["total_cpu_time"] as? [String: Any])
        let sampled = try XCTUnwrap(measurements["sampled_time"] as? [String: Any])
        let error = try XCTUnwrap(context["error"] as? [String: Any])
        let threads = try XCTUnwrap(context["threads"] as? [[String: Any]])

        XCTAssertEqual(diagnostic["kind"] as? String, "excessive_cpu")
        XCTAssertEqual(
            diagnostic["signature"] as? String,
            "metrickit:excessive_cpu:AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE:0x1240"
        )
        XCTAssertEqual(cpu["value"] as? Double, 98)
        XCTAssertEqual(cpu["unit"] as? String, "seconds")
        XCTAssertEqual(sampled["value"] as? Double, 60)
        XCTAssertEqual(error["mechanism"] as? String, "resource_diagnostic")
        XCTAssertNil(error["fatal"])
        XCTAssertNil(error["user_perceived"])
        XCTAssertNil(context["exception"])
        XCTAssertNil(context["termination"])
        XCTAssertEqual(threads.first?["role"] as? String, "sampled")
        XCTAssertEqual(threads.first?["triggered"] as? Bool, false)
        let tree = try XCTUnwrap(diagnostic["call_stack_tree"] as? [String: Any])
        let stacks = try XCTUnwrap(tree["stacks"] as? [[String: Any]])
        let roots = try XCTUnwrap(stacks.first?["root_frames"] as? [[String: Any]])
        XCTAssertEqual(stacks.first?["sample_count"] as? Double, 12)
        XCTAssertEqual(roots.first?["sample_count"] as? Double, 9)
    }

    func testMetricKitNormalizedKindNamesAndByteMeasurement() throws {
        XCTAssertEqual(LogisterMetricKitDiagnosticKind.diskWriteException.rawValue, "excessive_disk_writes")
        XCTAssertEqual(LogisterMetricKitDiagnosticKind.launchFailure.rawValue, "slow_launch")

        let context = try LogisterMetricKitAdapter.context(
            from: JSONSerialization.data(withJSONObject: ["totalWritesCaused": "1.5 GiB"]),
            kind: .diskWriteException
        ).mapValues(\.jsonObject)
        let diagnostic = try XCTUnwrap(context["diagnostic"] as? [String: Any])
        let measurements = try XCTUnwrap(diagnostic["measurements"] as? [String: Any])
        let writes = try XCTUnwrap(measurements["total_bytes_written"] as? [String: Any])

        XCTAssertEqual(diagnostic["kind"] as? String, "excessive_disk_writes")
        XCTAssertEqual(writes["value"] as? Double, 1_610_612_736)
        XCTAssertEqual(writes["unit"] as? String, "bytes")
        XCTAssertNil(context["exception"])
    }

    func testTokenCaching() async throws {
        let transport = CapturingTransport()
        let tokenProvider = SequenceTokenProvider(tokens: [
            LogisterToken(token: "mobile-token-1", expiresAt: Date().addingTimeInterval(300))
        ])
        let client = LogisterClient(
            endpoint: URL(string: "https://logister.example/api/v1/ingest_events")!,
            tokenProvider: tokenProvider,
            configuration: testConfiguration(),
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
            configuration: testConfiguration(),
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
            configuration: testConfiguration(),
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
            configuration: testConfiguration(),
            transport: transport
        )

        let response = try await client.captureMessage("one")
        let health = await client.healthSnapshot()
        XCTAssertEqual(response.deliveryState, .queued)
        XCTAssertEqual(health.queuedEventCount, 1)
        XCTAssertEqual(transport.sendCount, 0)
    }

    func testBlankTokenDoesNotSend() async throws {
        let transport = CapturingTransport()
        let client = LogisterClient(
            endpoint: URL(string: "https://logister.example/api/v1/ingest_events")!,
            tokenProvider: SequenceTokenProvider(tokens: [
                LogisterToken(token: "", expiresAt: Date().addingTimeInterval(300))
            ]),
            configuration: testConfiguration(),
            transport: transport
        )

        let response = try await client.captureMessage("one")
        let health = await client.healthSnapshot()
        XCTAssertEqual(response.deliveryState, .queued)
        XCTAssertEqual(health.queuedEventCount, 1)
        XCTAssertEqual(transport.sendCount, 0)
    }

    func testExpiredTokenDoesNotSend() async throws {
        let transport = CapturingTransport()
        let client = LogisterClient(
            endpoint: URL(string: "https://logister.example/api/v1/ingest_events")!,
            tokenProvider: SequenceTokenProvider(tokens: [
                LogisterToken(token: "expired-token", expiresAt: Date().addingTimeInterval(-1))
            ]),
            configuration: testConfiguration(),
            transport: transport
        )

        let response = try await client.captureMessage("one")
        let health = await client.healthSnapshot()
        XCTAssertEqual(response.deliveryState, .queued)
        XCTAssertEqual(health.queuedEventCount, 1)
        XCTAssertEqual(transport.sendCount, 0)
    }

    func testDurableQueueSurvivesClientRecreationAndPreservesIdentityAndTime() async throws {
        let directory = uniqueTestDirectory()
        let configuration = testConfiguration(scope: "durable", directory: directory)
        let firstClient = LogisterClient(
            endpoint: URL(string: "https://logister.example/api/v1/ingest_events")!,
            tokenProvider: FailingTokenProvider(),
            retryPolicy: .disabled,
            configuration: configuration,
            transport: CapturingTransport()
        )
        let eventID = UUID()
        let occurredAt = Date(timeIntervalSince1970: 1_786_272_000)
        let event = LogisterEvent(eventID: eventID, eventType: "log", message: "persist me", occurredAt: occurredAt)

        let queued = try await firstClient.capture(event)
        let firstHealth = await firstClient.healthSnapshot()
        XCTAssertEqual(queued.deliveryState, .queued)
        XCTAssertEqual(firstHealth.queuedEventCount, 1)

        let transport = CapturingTransport()
        let secondClient = LogisterClient(
            endpoint: URL(string: "https://logister.example/api/v1/ingest_events")!,
            tokenProvider: SequenceTokenProvider(tokens: [
                LogisterToken(token: "mobile-token", expiresAt: Date().addingTimeInterval(300))
            ]),
            retryPolicy: .disabled,
            configuration: configuration,
            transport: transport
        )

        let flushed = await secondClient.flushQueuedEvents()
        XCTAssertEqual(flushed, 1)
        let delivered = try XCTUnwrap(transport.envelope()["event"] as? [String: Any])
        XCTAssertEqual(delivered["uuid"] as? String, eventID.uuidString.lowercased())
        XCTAssertEqual(delivered["occurred_at"] as? String, LogisterDates.string(from: occurredAt))
        let secondHealth = await secondClient.healthSnapshot()
        XCTAssertEqual(secondHealth.queuedEventCount, 0)
    }

    func testSameEventIDIsDeduplicatedBeforeDelivery() async throws {
        let client = LogisterClient(
            endpoint: URL(string: "https://logister.example/api/v1/ingest_events")!,
            tokenProvider: FailingTokenProvider(),
            retryPolicy: .disabled,
            configuration: testConfiguration(),
            transport: CapturingTransport()
        )
        let event = LogisterEvent(eventID: UUID(), eventType: "log", message: "same source")

        _ = try await client.capture(event)
        _ = try await client.capture(event)

        let health = await client.healthSnapshot()
        XCTAssertEqual(health.queuedEventCount, 1)
    }

    func testStorageScopesCannotFlushEachOthersEnvelopes() async throws {
        let directory = uniqueTestDirectory()
        let endpoint = URL(string: "https://logister.example/api/v1/ingest_events")!
        let first = LogisterClient(
            endpoint: endpoint,
            tokenProvider: FailingTokenProvider(),
            retryPolicy: .disabled,
            configuration: testConfiguration(scope: "project-a", directory: directory),
            transport: CapturingTransport()
        )
        _ = try await first.captureMessage("project a")

        let transport = CapturingTransport()
        let second = LogisterClient(
            endpoint: endpoint,
            tokenProvider: SequenceTokenProvider(tokens: [
                LogisterToken(token: "project-b-token", expiresAt: Date().addingTimeInterval(300))
            ]),
            retryPolicy: .disabled,
            configuration: testConfiguration(scope: "project-b", directory: directory),
            transport: transport
        )

        let flushed = await second.flushQueuedEvents()
        XCTAssertEqual(flushed, 0)
        XCTAssertEqual(transport.sendCount, 0)
        let firstHealth = await first.healthSnapshot()
        XCTAssertEqual(firstHealth.queuedEventCount, 1)
    }

    func testPermanentRejectionDoesNotBlockLaterEvents() async throws {
        let transport = CapturingTransport(responses: [
            LogisterResponse(statusCode: 422),
            LogisterResponse(statusCode: 201)
        ])
        let client = LogisterClient(
            endpoint: URL(string: "https://logister.example/api/v1/ingest_events")!,
            tokenProvider: SequenceTokenProvider(tokens: [
                LogisterToken(token: "mobile-token", expiresAt: Date().addingTimeInterval(300))
            ]),
            retryPolicy: .disabled,
            configuration: testConfiguration(),
            transport: transport
        )

        let rejected = try await client.captureMessage("invalid")
        let accepted = try await client.captureMessage("valid")
        XCTAssertEqual(rejected.deliveryState, .rejected)
        XCTAssertTrue(accepted.accepted)
        let health = await client.healthSnapshot()
        XCTAssertEqual(health.queuedEventCount, 0)
        XCTAssertEqual(health.discardedEventCount, 1)
    }

    func testUnauthorizedResponseRefreshesTokenOnce() async throws {
        let transport = CapturingTransport(responses: [
            LogisterResponse(statusCode: 401),
            LogisterResponse(statusCode: 201)
        ])
        let provider = SequenceTokenProvider(tokens: [
            LogisterToken(token: "mobile-token-1", expiresAt: Date().addingTimeInterval(300)),
            LogisterToken(token: "mobile-token-2", expiresAt: Date().addingTimeInterval(300))
        ])
        let client = LogisterClient(
            endpoint: URL(string: "https://logister.example/api/v1/ingest_events")!,
            tokenProvider: provider,
            retryPolicy: .disabled,
            configuration: testConfiguration(),
            transport: transport
        )

        let response = try await client.captureMessage("refresh")
        let fetchCount = await provider.fetchCount
        XCTAssertTrue(response.accepted)
        XCTAssertEqual(fetchCount, 2)
        XCTAssertEqual(
            transport.requests.compactMap { $0.value(forHTTPHeaderField: "Authorization") },
            ["Bearer mobile-token-1", "Bearer mobile-token-2"]
        )
    }

    func testConcurrentCaptureCoalescesTokenRefreshAndDrainsEveryEnvelope() async throws {
        let transport = CapturingTransport(responses: (0..<10).map { _ in LogisterResponse(statusCode: 201) })
        let provider = SequenceTokenProvider(tokens: [
            LogisterToken(token: "mobile-token", expiresAt: Date().addingTimeInterval(300))
        ])
        let client = LogisterClient(
            endpoint: URL(string: "https://logister.example/api/v1/ingest_events")!,
            tokenProvider: provider,
            exceptionDataPolicy: .typeAndStacktrace,
            configuration: testConfiguration(),
            transport: transport
        )

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<10 {
                group.addTask {
                    _ = try? await client.captureMessage("event-\(index)")
                }
            }
        }
        _ = await client.flushQueuedEvents()

        let fetchCount = await provider.fetchCount
        let health = await client.healthSnapshot()
        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(transport.sendCount, 10)
        XCTAssertEqual(health.queuedEventCount, 0)
    }

    func testConsentDisablePurgesQueueAndStopsCapture() async throws {
        let client = LogisterClient(
            endpoint: URL(string: "https://logister.example/api/v1/ingest_events")!,
            tokenProvider: FailingTokenProvider(),
            retryPolicy: .disabled,
            configuration: testConfiguration(),
            transport: CapturingTransport()
        )
        _ = try await client.captureMessage("queued before opt out")
        let queuedHealth = await client.healthSnapshot()
        XCTAssertEqual(queuedHealth.queuedEventCount, 1)

        await client.setCollectionEnabled(false)
        let response = try await client.captureMessage("must not collect")

        let health = await client.healthSnapshot()
        XCTAssertEqual(response.deliveryState, .dropped)
        XCTAssertFalse(health.collectionEnabled)
        XCTAssertEqual(health.queuedEventCount, 0)
    }

    func testCollectionCategoriesCanDisableLogsWithoutDisablingErrors() async throws {
        let transport = CapturingTransport()
        let client = LogisterClient(
            endpoint: URL(string: "https://logister.example/api/v1/ingest_events")!,
            tokenProvider: SequenceTokenProvider(tokens: [
                LogisterToken(token: "mobile-token", expiresAt: Date().addingTimeInterval(300))
            ]),
            exceptionDataPolicy: .typeAndStacktrace,
            configuration: LogisterConfiguration(
                enabledCategories: [.errors],
                storageScope: UUID().uuidString,
                storageDirectory: uniqueTestDirectory()
            ),
            transport: transport
        )

        let log = try await client.captureMessage("disabled log")
        let error = try await client.captureException(NSError(domain: "Sample", code: 1))

        XCTAssertEqual(log.deliveryState, .dropped)
        XCTAssertTrue(error.accepted)
        XCTAssertEqual(transport.sendCount, 1)
    }

    func testInstallationPseudonymIsScopedPersistentAndLabeledAsDeliveryEvidence() async throws {
        let transport = CapturingTransport(responses: [
            LogisterResponse(statusCode: 201),
            LogisterResponse(statusCode: 201)
        ])
        let configuration = LogisterConfiguration(
            storageScope: "installation",
            storageDirectory: uniqueTestDirectory(),
            installationTrackingEnabled: true
        )
        let client = LogisterClient(
            endpoint: URL(string: "https://logister.example/api/v1/ingest_events")!,
            tokenProvider: SequenceTokenProvider(tokens: [
                LogisterToken(token: "mobile-token", expiresAt: Date().addingTimeInterval(300))
            ]),
            configuration: configuration,
            transport: transport
        )

        _ = try await client.captureMessage("one")
        _ = try await client.captureMessage("two")

        let installations = try transport.bodies.map { body -> [String: Any] in
            let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let event = try XCTUnwrap(envelope["event"] as? [String: Any])
            let context = try XCTUnwrap(event["context"] as? [String: Any])
            return try XCTUnwrap(context["installation"] as? [String: Any])
        }
        XCTAssertEqual(installations[0]["id_hash"] as? String, installations[1]["id_hash"] as? String)
        XCTAssertEqual(installations[0]["scope"] as? String, "delivery_installation")
    }

    func testBeforeSendIsResanitizedAndCannotReplaceIdentityOrEvidence() async throws {
        let transport = CapturingTransport()
        let configuration = LogisterConfiguration(
            storageScope: UUID().uuidString,
            storageDirectory: uniqueTestDirectory(),
            beforeSend: { payload in
                var payload = payload
                payload["uuid"] = .string(UUID().uuidString)
                payload["authorization"] = .string("Bearer private-token")
                payload["callback"] = .string("https://example.test/path?secret=value#fragment")
                payload["evidence"] = .object(["source": .string("fabricated")])
                return payload
            }
        )
        let eventID = UUID()
        let client = LogisterClient(
            endpoint: URL(string: "https://logister.example/api/v1/ingest_events")!,
            tokenProvider: SequenceTokenProvider(tokens: [
                LogisterToken(token: "mobile-token", expiresAt: Date().addingTimeInterval(300))
            ]),
            configuration: configuration,
            transport: transport
        )

        _ = try await client.capture(LogisterEvent(eventID: eventID, eventType: "log", message: "redact"))

        let event = try XCTUnwrap(transport.envelope()["event"] as? [String: Any])
        XCTAssertEqual(event["uuid"] as? String, eventID.uuidString.lowercased())
        XCTAssertNil(event["authorization"])
        XCTAssertEqual(event["callback"] as? String, "https://example.test/path")
        XCTAssertEqual((event["evidence"] as? [String: Any])?["source"] as? String, "sdk")
    }

    func testMetricKitSourcePayloadOverridesUploaderRuntimeFacts() async throws {
        let transport = CapturingTransport()
        let client = LogisterClient(
            endpoint: URL(string: "https://logister.example/api/v1/ingest_events")!,
            tokenProvider: SequenceTokenProvider(tokens: [
                LogisterToken(token: "mobile-token", expiresAt: Date().addingTimeInterval(300))
            ]),
            environment: "current-environment",
            release: "current-release",
            configuration: testConfiguration(),
            transport: transport
        )
        let diagnostic: [String: Any] = [
            "applicationVersion": "3.0",
            "terminationReason": "private reason",
            "callStackTree": ["callStacks": []]
        ]
        let sourcePayload: [String: Any] = [
            "timeStampBegin": "2026-08-01T00:00:00Z",
            "timeStampEnd": "2026-08-02T00:00:00Z",
            "metaData": [
                "applicationBuildVersion": "42",
                "deviceType": "iPhone17,1",
                "osVersion": "iPhone OS 19.0 (23A1)",
                "platformArchitecture": "arm64",
                "isTestFlightApp": true
            ]
        ]

        _ = try await client.captureMetricKitDiagnostic(
            JSONSerialization.data(withJSONObject: diagnostic),
            kind: .hang,
            dataPolicy: .typeAndStacktrace,
            sourcePayload: JSONSerialization.data(withJSONObject: sourcePayload)
        )

        let event = try XCTUnwrap(transport.envelope()["event"] as? [String: Any])
        let context = try XCTUnwrap(event["context"] as? [String: Any])
        let evidence = try XCTUnwrap(event["evidence"] as? [String: Any])
        let sourceEvidence = try XCTUnwrap(context["source_evidence"] as? [String: Any])
        XCTAssertNil(event["occurred_at"])
        XCTAssertNil(event["environment"])
        XCTAssertNil(event["release"])
        XCTAssertEqual((context["app"] as? [String: Any])?["version_name"] as? String, "3.0")
        XCTAssertEqual((context["app"] as? [String: Any])?["version_code"] as? String, "42")
        XCTAssertEqual((context["device"] as? [String: Any])?["model_identifier"] as? String, "iPhone17,1")
        XCTAssertEqual((context["distribution"] as? [String: Any])?["channel"] as? String, "testflight")
        XCTAssertNil((sourceEvidence["diagnostic"] as? [String: Any])?["terminationReason"])
        XCTAssertEqual((evidence["reporting_period"] as? [String: Any])?["end"] as? String, "2026-08-02T00:00:00Z")
    }
}

private func testConfiguration(
    scope: String = UUID().uuidString,
    directory: URL = uniqueTestDirectory()
) -> LogisterConfiguration {
    LogisterConfiguration(
        storageScope: scope,
        storageDirectory: directory
    )
}

private func uniqueTestDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("logister-ios-tests-\(UUID().uuidString)", isDirectory: true)
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
