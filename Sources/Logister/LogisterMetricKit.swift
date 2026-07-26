import CryptoKit
import Foundation

public enum LogisterMetricKitDiagnosticKind: String, Sendable {
    case crash
    case hang
    case cpuException = "cpu_exception"
    case diskWriteException = "disk_write_exception"
    case launchFailure = "launch_failure"
    case memoryTermination = "memory_termination"

    var mechanism: String {
        switch self {
        case .crash: "native_crash"
        case .hang: "hang"
        case .cpuException: "unhandled_exception"
        case .diskWriteException: "disk_write_exception"
        case .launchFailure: "launch_failure"
        case .memoryTermination: "memory_termination"
        }
    }

    var fatal: Bool {
        switch self {
        case .crash, .memoryTermination: true
        default: false
        }
    }

    var displayName: String {
        switch self {
        case .crash: "crash"
        case .hang: "hang"
        case .cpuException: "CPU exception"
        case .diskWriteException: "disk-write exception"
        case .launchFailure: "launch failure"
        case .memoryTermination: "memory termination"
        }
    }
}

extension LogisterClient {
    /// Uploads one MetricKit diagnostic. The caller should pass the JSON for an
    /// individual diagnostic, not the daily aggregate payload.
    @discardableResult
    public func captureMetricKitDiagnostic(
        _ data: Data,
        kind: LogisterMetricKitDiagnosticKind
    ) async throws -> LogisterResponse {
        let context = try LogisterMetricKitAdapter.context(from: data, kind: kind)
        return try await capture(
            LogisterEvent(
                eventID: LogisterMetricKitAdapter.eventID(from: data),
                eventType: "error",
                message: "MetricKit \(kind.displayName)",
                level: kind.fatal ? "fatal" : "error",
                context: context
            )
        )
    }
}

enum LogisterMetricKitAdapter {
    static let maximumPayloadBytes = 2_000_000

    static func eventID(from data: Data) -> UUID {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let first = String(digest.prefix(8))
        let second = String(digest.dropFirst(8).prefix(4))
        let third = String(digest.dropFirst(12).prefix(4))
        let fourth = String(digest.dropFirst(16).prefix(4))
        let fifth = String(digest.dropFirst(20).prefix(12))
        let value = "\(first)-\(second)-\(third)-\(fourth)-\(fifth)"
        // A SHA-256 digest always yields the 32 hexadecimal digits needed here.
        return UUID(uuidString: value)!
    }

    static func context(from data: Data, kind: LogisterMetricKitDiagnosticKind) throws -> LogisterContext {
        guard !data.isEmpty, data.count <= maximumPayloadBytes else {
            throw LogisterError.invalidPayload
        }
        let object = try JSONSerialization.jsonObject(with: data)
        guard let raw = object as? [String: Any] else {
            throw LogisterError.invalidPayload
        }

        let threads = normalizedThreads(raw)
        let triggeredFrames = threads.first(where: { thread in
            guard case .object(let value) = thread else { return false }
            guard case .bool(let triggered) = value["triggered"] else { return false }
            return triggered
        }).flatMap { thread -> [LogisterValue]? in
            guard case .object(let value) = thread, case .array(let frames) = value["frames"] else { return nil }
            return frames
        } ?? []
        let signature = diagnosticSignature(kind: kind, threads: threads, raw: raw)
        let externalID = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let missingUUIDs = applicationUUIDs(in: threads)

        var diagnostic: LogisterContext = [
            "source": .string("metrickit"),
            "kind": .string(kind.rawValue),
            "external_id": .string(externalID)
        ]
        if let signature { diagnostic["signature"] = .string(signature) }

        var exception: LogisterContext = [
            "type": .string(exceptionType(raw, kind: kind)),
            "threads": .array(threads),
            "stacktrace": .array(triggeredFrames)
        ]
        put(raw["exceptionCode"], into: &exception, key: "code")
        put(raw["signal"], into: &exception, key: "signal")

        var termination: LogisterContext = ["namespace": .string("MetricKit")]
        put(raw["terminationReason"] ?? raw["exceptionReason"], into: &termination, key: "reason")
        put(raw["exceptionCode"] ?? raw["signal"], into: &termination, key: "code")

        var context: LogisterContext = [
            "diagnostic": .object(diagnostic),
            "error": .object([
                "mechanism": .string(kind.mechanism),
                "handled": .bool(false),
                "fatal": .bool(kind.fatal),
                "user_perceived": .bool(kind == .crash || kind == .hang || kind == .launchFailure)
            ]),
            "exception": .object(exception),
            "termination": .object(termination),
            "symbolication": .object([
                "status": .string(missingUUIDs.isEmpty ? "unknown" : "missing"),
                "missing_uuids": .array(missingUUIDs.map(LogisterValue.string))
            ])
        ]
        if let rawValue = LogisterValue(jsonObject: raw) {
            context["metrickit"] = rawValue
        }
        return LogisterPrivacySanitizer.sanitize(context)
    }

    private static func normalizedThreads(_ raw: [String: Any]) -> [LogisterValue] {
        let tree = (raw["callStackTree"] as? [String: Any]) ?? raw
        let stacks = tree["callStacks"] as? [[String: Any]] ?? []
        return stacks.enumerated().map { index, stack in
            let roots = stack["callStackRootFrames"] as? [[String: Any]] ?? []
            return .object([
                "id": .string(String(index)),
                "name": .string("Thread \(index)"),
                "triggered": .bool(stack["threadAttributed"] as? Bool ?? false),
                "frames": .array(flatten(roots))
            ])
        }
    }

    private static func flatten(_ frames: [[String: Any]]) -> [LogisterValue] {
        frames.flatMap { frame -> [LogisterValue] in
            let image = frame["binaryName"] as? String
            var value: LogisterContext = [
                "application_frame": .bool(image == ProcessInfo.processInfo.processName)
            ]
            put(image, into: &value, key: "image")
            put(frame["binaryUUID"], into: &value, key: "image_uuid")
            put(frame["address"], into: &value, key: "address")
            put(frame["offsetIntoBinaryTextSegment"], into: &value, key: "relative_address")
            let children = frame["subFrames"] as? [[String: Any]] ?? []
            return [.object(value)] + flatten(children)
        }
    }

    private static func diagnosticSignature(
        kind: LogisterMetricKitDiagnosticKind,
        threads: [LogisterValue],
        raw: [String: Any]
    ) -> String? {
        for thread in threads {
            guard case .object(let threadValue) = thread,
                  case .bool(true) = threadValue["triggered"],
                  case .array(let frames) = threadValue["frames"] else { continue }
            for frame in frames {
                guard case .object(let frameValue) = frame,
                      case .string(let uuid) = frameValue["image_uuid"],
                      let offset = stringValue(frameValue["relative_address"]) else { continue }
                return "metrickit:\(kind.rawValue):\(uuid.uppercased()):\(offset)"
            }
        }

        let type = stringValue(LogisterValue(jsonObject: raw["exceptionType"] as Any))
        let code = stringValue(LogisterValue(jsonObject: raw["exceptionCode"] as Any))
        guard type != nil || code != nil else { return nil }
        return ["metrickit", kind.rawValue, type, code].compactMap { $0 }.joined(separator: ":")
    }

    private static func applicationUUIDs(in threads: [LogisterValue]) -> [String] {
        var values: [String] = []
        for thread in threads {
            guard case .object(let threadValue) = thread, case .array(let frames) = threadValue["frames"] else { continue }
            for frame in frames {
                guard case .object(let frameValue) = frame,
                      case .bool(true) = frameValue["application_frame"],
                      case .string(let uuid) = frameValue["image_uuid"] else { continue }
                values.append(uuid.uppercased())
            }
        }
        return Array(Set(values)).sorted()
    }

    private static func exceptionType(_ raw: [String: Any], kind: LogisterMetricKitDiagnosticKind) -> String {
        stringValue(LogisterValue(jsonObject: raw["exceptionType"] as Any)) ?? "MetricKit \(kind.displayName)"
    }

    private static func put(_ raw: Any?, into context: inout LogisterContext, key: String) {
        guard let raw, let value = LogisterValue(jsonObject: raw) else { return }
        context[key] = value
    }

    private static func stringValue(_ value: LogisterValue?) -> String? {
        switch value {
        case .string(let value): value
        case .number(let value): String(value)
        default: nil
        }
    }
}

#if canImport(MetricKit) && (os(iOS) || os(macOS))
import MetricKit

/// Opt-in bridge for the MetricKit API available on the package's deployment
/// targets. Keep one instance alive for the app lifetime and call `start()`.
/// Apple replaces this subscriber API with `MetricManager` async sequences on
/// iOS 27/macOS 27; a future package built with that SDK can switch internally
/// without changing the Logister event contract.
@available(iOS 15.0, macOS 13.0, *)
public final class LogisterMetricKitCollector: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    private let client: LogisterClient
    private let onUploadError: (@Sendable (String) -> Void)?
    private var started = false

    public init(client: LogisterClient, onUploadError: (@Sendable (String) -> Void)? = nil) {
        self.client = client
        self.onUploadError = onUploadError
    }

    public func start() {
        guard !started else { return }
        started = true
        MXMetricManager.shared.add(self)
    }

    public func stop() {
        guard started else { return }
        MXMetricManager.shared.remove(self)
        started = false
    }

    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            payload.crashDiagnostics?.forEach { upload($0.jsonRepresentation(), kind: .crash) }
            payload.hangDiagnostics?.forEach { upload($0.jsonRepresentation(), kind: .hang) }
            payload.cpuExceptionDiagnostics?.forEach { upload($0.jsonRepresentation(), kind: .cpuException) }
            payload.diskWriteExceptionDiagnostics?.forEach { upload($0.jsonRepresentation(), kind: .diskWriteException) }
        }
    }

    private func upload(_ data: Data, kind: LogisterMetricKitDiagnosticKind) {
        Task { [client, onUploadError] in
            do {
                try await client.captureMetricKitDiagnostic(data, kind: kind)
            } catch {
                onUploadError?(String(describing: error))
            }
        }
    }
}
#endif
