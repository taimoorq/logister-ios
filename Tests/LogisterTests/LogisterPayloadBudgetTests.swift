import Foundation
import XCTest
@testable import Logister

final class LogisterPayloadBudgetTests: XCTestCase {
    func testRealisticMetricKitCrashIsAcceptedWithinServerLimits() async throws {
        let transport = CapturingTransport()
        let client = budgetTestClient(transport: transport)
        let data = try JSONSerialization.data(
            withJSONObject: crashDiagnosticFixture(threads: 16, framesPerThread: 30, attributedThread: 7),
            options: [.sortedKeys]
        )

        let response = try await client.captureMetricKitDiagnostic(data, kind: .crash)

        XCTAssertTrue(response.accepted)
        let event = try XCTUnwrap(transport.envelope()["event"] as? [String: Any])
        XCTAssertEqual(event["uuid"] as? String, LogisterMetricKitAdapter.eventID(from: data).uuidString.lowercased())
        XCTAssertEqual(event["event_type"] as? String, "error")
        XCTAssertEqual(event["message"] as? String, "MetricKit crash")
        XCTAssertEqual(event["level"] as? String, "fatal")
        XCTAssertNotNil(event["evidence"] as? [String: Any])

        let context = try XCTUnwrap(event["context"] as? [String: Any])
        let exception = try XCTUnwrap(context["exception"] as? [String: Any])
        let threads = try XCTUnwrap(exception["threads"] as? [[String: Any]])
        let crashed = try XCTUnwrap(threads.first)
        XCTAssertEqual(crashed["triggered"] as? Bool, true)
        XCTAssertEqual(crashed["id"] as? String, "7")
        XCTAssertEqual((crashed["frames"] as? [[String: Any]])?.count, 30)
        XCTAssertEqual((exception["stacktrace"] as? [[String: Any]])?.count, 30)
        XCTAssertEqual(exception["code"] as? Double, 0)
        XCTAssertFalse(isJSONBoolean(exception["code"]))
        XCTAssertEqual(exception["type"] as? String, "1.0")
        XCTAssertEqual(exception["signal"] as? Double, 11)
        let firstFrame = try XCTUnwrap((crashed["frames"] as? [[String: Any]])?.first)
        XCTAssertEqual(firstFrame["sample_count"] as? Double, 1)
        XCTAssertFalse(isJSONBoolean(firstFrame["sample_count"]))
        XCTAssertTrue(isJSONBoolean(firstFrame["application_frame"]))
        XCTAssertEqual((context["diagnostic"] as? [String: Any])?["signature"] as? String,
                       "metrickit:crash:AAAAAAAA-BBBB-CCCC-DDDD-000000000007:0x1000")
        XCTAssertEqual((context["os"] as? [String: Any])?["version"] as? String, "iPhone OS 17.4 (21E219)")
        XCTAssertEqual((context["app"] as? [String: Any])?["version_name"] as? String, "3.1")
        XCTAssertEqual((context["sdk"] as? [String: Any])?["name"] as? String, "logister-ios")
        XCTAssertEqual(context["_truncated"] as? Bool, true)
        // A linear crash tree repeats the flattened threads, and the raw source
        // copy repeats the whole diagnostic, so neither is sent.
        XCTAssertNil((context["diagnostic"] as? [String: Any])?["call_stack_tree"])
        XCTAssertNil((context["source_evidence"] as? [String: Any])?["diagnostic"])

        let serialized = String(decoding: try XCTUnwrap(transport.body), as: UTF8.self)
        XCTAssertFalse(serialized.contains("private termination detail"))
        XCTAssertFalse(serialized.contains("composed private message"))
        try assertWithinServerLimits(event)
    }

    func testSmallMetricKitCrashIsNotMarkedTruncated() async throws {
        let transport = CapturingTransport()
        let client = budgetTestClient(transport: transport)
        let data = try JSONSerialization.data(
            withJSONObject: crashDiagnosticFixture(threads: 2, framesPerThread: 5, attributedThread: 0)
        )

        let response = try await client.captureMetricKitDiagnostic(data, kind: .crash)

        XCTAssertTrue(response.accepted)
        let event = try XCTUnwrap(transport.envelope()["event"] as? [String: Any])
        let context = try XCTUnwrap(event["context"] as? [String: Any])
        let threads = try XCTUnwrap((context["exception"] as? [String: Any])?["threads"] as? [[String: Any]])
        XCTAssertNil(context["_truncated"])
        XCTAssertEqual(threads.count, 2)
        try assertWithinServerLimits(event)
    }

    func testOversizedContextKeepsRequiredEnvelopeFields() async throws {
        let transport = CapturingTransport()
        let client = budgetTestClient(transport: transport)
        let large = (0..<2_000).reduce(into: LogisterContext()) { result, index in
            result[String(format: "a%04d", index)] = .object(["value": .number(Double(index))])
        }

        let response = try await client.captureMessage("still delivered", options: LogisterEventOptions(context: large))

        XCTAssertTrue(response.accepted)
        let event = try XCTUnwrap(transport.envelope()["event"] as? [String: Any])
        XCTAssertNotNil(event["uuid"] as? String)
        XCTAssertNotNil(event["occurred_at"] as? String)
        XCTAssertEqual(event["event_type"] as? String, "log")
        XCTAssertEqual(event["message"] as? String, "still delivered")
        let context = try XCTUnwrap(event["context"] as? [String: Any])
        XCTAssertEqual(context["_truncated"] as? Bool, true)
        XCTAssertEqual(context["platform"] as? String, "ios")
        XCTAssertNotNil(context["sdk"] as? [String: Any])
        try assertWithinServerLimits(event)
    }

    func testOversizedStringsAreShrunkToTheByteBudgetInsteadOfRejected() async throws {
        let transport = CapturingTransport()
        let client = budgetTestClient(
            transport: transport,
            policy: LogisterPayloadPolicy(maximumStringLength: 32_768, maximumEnvelopeBytes: 64 * 1_024)
        )
        let large = (0..<40).reduce(into: LogisterContext()) { result, index in
            result["field_\(index)"] = .string(String(repeating: "x", count: 30_000))
        }

        let response = try await client.captureMessage("bounded", options: LogisterEventOptions(context: large))

        XCTAssertTrue(response.accepted)
        let body = try XCTUnwrap(transport.body)
        XCTAssertLessThanOrEqual(body.count, 64 * 1_024)
        let event = try XCTUnwrap(transport.envelope()["event"] as? [String: Any])
        XCTAssertEqual(event["message"] as? String, "bounded")
        XCTAssertEqual((event["context"] as? [String: Any])?["_truncated"] as? Bool, true)
    }

    func testNonFiniteNumbersDoNotCrashSerialization() async throws {
        let transport = CapturingTransport()
        let client = budgetTestClient(transport: transport)

        let response = try await client.captureMetric(
            "ratio",
            value: .nan,
            options: LogisterEventOptions(context: ["limit": .number(.infinity)])
        )

        XCTAssertTrue(response.accepted)
        let context = try XCTUnwrap((transport.envelope()["event"] as? [String: Any])?["context"] as? [String: Any])
        XCTAssertTrue(context["value"] is NSNull)
        XCTAssertTrue(context["limit"] is NSNull)
    }
}

private func budgetTestClient(
    transport: CapturingTransport,
    policy: LogisterPayloadPolicy = .default
) -> LogisterClient {
    LogisterClient(
        endpoint: URL(string: "https://logister.example/api/v1/ingest_events")!,
        tokenProvider: SequenceTokenProvider(tokens: [
            LogisterToken(token: "mobile-token", expiresAt: Date().addingTimeInterval(300))
        ]),
        exceptionDataPolicy: .typeAndStacktrace,
        configuration: LogisterConfiguration(
            storageScope: UUID().uuidString,
            storageDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("logister-ios-tests-\(UUID().uuidString)", isDirectory: true),
            payloadPolicy: policy
        ),
        transport: transport
    )
}

/// Mirrors the shape of `MXCrashDiagnostic.jsonRepresentation()`: one linear
/// call chain per thread and Apple's `diagnosticMetaData` block.
func crashDiagnosticFixture(threads: Int, framesPerThread: Int, attributedThread: Int) -> [String: Any] {
    func chain(thread: Int, depth: Int) -> [String: Any] {
        let application = depth < 4
        var frame: [String: Any] = [
            "binaryName": application ? ProcessInfo.processInfo.processName : "UIKitCore",
            "binaryUUID": String(format: "AAAAAAAA-BBBB-CCCC-DDDD-%012d", application ? thread : 999),
            "address": 4_294_967_296 + thread * 65_536 + depth * 16,
            "offsetIntoBinaryTextSegment": 4_096 + depth * 16,
            "sampleCount": 1
        ]
        if depth + 1 < framesPerThread {
            frame["subFrames"] = [chain(thread: thread, depth: depth + 1)]
        }
        return frame
    }
    return [
        "version": "1.0.0",
        "callStackTree": [
            "callStackPerThread": true,
            "callStacks": (0..<threads).map { index in
                [
                    "threadAttributed": index == attributedThread,
                    "callStackRootFrames": [chain(thread: index, depth: 0)]
                ] as [String: Any]
            }
        ],
        "diagnosticMetaData": [
            "appBuildVersion": "42",
            "appVersion": "3.1",
            "bundleIdentifier": "com.example.shop",
            "deviceType": "iPhone15,2",
            "exceptionCode": 0,
            "exceptionType": 1,
            "isTestFlightApp": false,
            "lowPowerModeEnabled": false,
            "osVersion": "iPhone OS 17.4 (21E219)",
            "pid": 4_242,
            "platformArchitecture": "arm64e",
            "regionFormat": "US",
            "signal": 11,
            "terminationReason": "private termination detail",
            "virtualMemoryRegionInfo": "0 is not in any region.",
            "exceptionReason": [
                "composedMessage": "composed private message",
                "exceptionName": "NSInvalidArgumentException"
            ]
        ]
    ]
}

func isJSONBoolean(_ value: Any?) -> Bool {
    guard let value = value as? NSNumber else { return false }
    return CFGetTypeID(value) == CFBooleanGetTypeID()
}

/// Mirrors `TelemetryPayloadLimits` in the Logister server, which answers 413
/// for an event over these limits.
func assertWithinServerLimits(_ event: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws {
    var keys = 0
    var maximumDepth = 0
    var longestArray = 0
    func walk(_ value: Any, depth: Int) {
        maximumDepth = max(maximumDepth, depth)
        if let object = value as? [String: Any] {
            keys += object.count
            object.values.forEach { walk($0, depth: depth + 1) }
        } else if let array = value as? [Any] {
            longestArray = max(longestArray, array.count)
            array.forEach { walk($0, depth: depth + 1) }
        }
    }
    walk(event, depth: 0)
    let bytes = try JSONSerialization.data(withJSONObject: event).count
    XCTAssertLessThanOrEqual(keys, 512, "server MAX_CONTEXT_KEYS", file: file, line: line)
    XCTAssertLessThanOrEqual(maximumDepth, 16, "server MAX_CONTEXT_DEPTH", file: file, line: line)
    XCTAssertLessThanOrEqual(longestArray, 1_000, "server MAX_ARRAY_LENGTH", file: file, line: line)
    XCTAssertLessThanOrEqual(bytes, 1_000_000, "server MAX_EVENT_BYTES", file: file, line: line)
}
