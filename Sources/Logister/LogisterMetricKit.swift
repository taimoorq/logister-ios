import CryptoKit
import Foundation

public enum LogisterMetricKitDiagnosticKind: String, Sendable {
    case crash
    case hang
    case cpuException = "excessive_cpu"
    case diskWriteException = "excessive_disk_writes"
    case launchFailure = "slow_launch"
    case memoryTermination = "memory_termination"

    var mechanism: String {
        switch self {
        case .crash: "native_crash"
        case .hang: "hang"
        case .cpuException, .diskWriteException: "resource_diagnostic"
        case .launchFailure: "performance_diagnostic"
        case .memoryTermination: "memory_termination"
        }
    }

    var fatal: Bool? {
        switch self {
        case .crash, .memoryTermination: true
        case .hang: false
        case .cpuException, .diskWriteException, .launchFailure: nil
        }
    }

    var displayName: String {
        switch self {
        case .crash: "crash"
        case .hang: "hang"
        case .cpuException: "excessive CPU diagnostic"
        case .diskWriteException: "excessive disk-write diagnostic"
        case .launchFailure: "slow-launch diagnostic"
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
        try await captureMetricKitDiagnostic(
            data,
            kind: kind,
            dataPolicy: .typeAndStacktrace
        )
    }

    /// Uploads one MetricKit diagnostic using an explicit exception-data policy.
    @discardableResult
    public func captureMetricKitDiagnostic(
        _ data: Data,
        kind: LogisterMetricKitDiagnosticKind,
        dataPolicy: LogisterExceptionDataPolicy
    ) async throws -> LogisterResponse {
        try await captureMetricKitDiagnostic(
            data,
            kind: kind,
            dataPolicy: dataPolicy,
            sourcePayload: nil
        )
    }

    @discardableResult
    func captureMetricKitDiagnostic(
        _ data: Data,
        kind: LogisterMetricKitDiagnosticKind,
        dataPolicy: LogisterExceptionDataPolicy,
        sourcePayload: Data?
    ) async throws -> LogisterResponse {
        let context = try LogisterMetricKitAdapter.context(
            from: data,
            kind: kind,
            dataPolicy: dataPolicy,
            sourcePayload: sourcePayload
        )
        return try await capture(
            LogisterEvent(
                eventID: LogisterMetricKitAdapter.eventID(from: data),
                eventType: "error",
                message: "MetricKit \(kind.displayName)",
                level: kind.fatal == true ? "fatal" : "error",
                context: context
            )
        )
    }
}

enum LogisterMetricKitAdapter {
    static let maximumPayloadBytes = 2_000_000
    static let maximumThreads = 64
    static let maximumFramesPerThread = 100
    static let maximumCallTreeDepth = 64

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

    static func context(
        from data: Data,
        kind: LogisterMetricKitDiagnosticKind,
        dataPolicy: LogisterExceptionDataPolicy = .typeAndStacktrace,
        sourcePayload: Data? = nil
    ) throws -> LogisterContext {
        guard !data.isEmpty, data.count <= maximumPayloadBytes else {
            throw LogisterError.invalidPayload
        }
        let object = try JSONSerialization.jsonObject(with: data)
        guard let raw = object as? [String: Any] else {
            throw LogisterError.invalidPayload
        }
        let sourceRaw = sourcePayload.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let metadata = (sourceRaw?["metaData"] as? [String: Any])
            ?? (sourceRaw?["metadata"] as? [String: Any])
            ?? [:]

        let callStackTree = normalizedCallStackTree(raw, kind: kind)
        let threads = normalizedThreads(raw, kind: kind)
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
        let reportingSource = sourceRaw ?? raw
        if let start = stringValue(LogisterValue(jsonObject: reportingSource["timeStampBegin"] as Any)),
           let end = stringValue(LogisterValue(jsonObject: reportingSource["timeStampEnd"] as Any)) {
            diagnostic["reporting_period"] = .object([
                "start": .string(start),
                "end": .string(end)
            ])
        }
        if let signature { diagnostic["signature"] = .string(signature) }
        diagnostic["binary_uuids"] = .array(missingUUIDs.map(LogisterValue.string))
        if let callStackTree { diagnostic["call_stack_tree"] = callStackTree }
        let measurements = normalizedMeasurements(raw, kind: kind)
        if !measurements.isEmpty { diagnostic["measurements"] = .object(measurements) }

        var error: LogisterContext = [
            "mechanism": .string(kind.mechanism),
            "capture_source": .string("metrickit"),
            "data_policy": .string(dataPolicy.rawValue)
        ]
        if kind == .crash { error["handled"] = .bool(false) }
        if let fatal = kind.fatal { error["fatal"] = .bool(fatal) }
        if let userPerceived = raw["userPerceived"] as? Bool {
            error["user_perceived"] = .bool(userPerceived)
        }
        error["thread_role"] = .string(primaryThreadRole(kind))

        var context: LogisterContext = [
            "diagnostic": .object(diagnostic),
            "error": .object(error)
        ]
        if kind == .crash {
            var exception: LogisterContext = [
                "type": .string(exceptionType(raw, kind: kind)),
                "threads": .array(threads),
                "stacktrace": .array(triggeredFrames)
            ]
            put(raw["exceptionCode"], into: &exception, key: "code")
            put(raw["signal"], into: &exception, key: "signal")
            context["exception"] = .object(exception)
        } else if !threads.isEmpty {
            context["threads"] = .array(threads)
        }
        if kind == .crash || kind == .memoryTermination {
            var termination: LogisterContext = ["namespace": .string("MetricKit")]
            if dataPolicy == .full {
                put(raw["terminationReason"] ?? raw["exceptionReason"], into: &termination, key: "reason")
            }
            put(raw["exceptionCode"] ?? raw["signal"], into: &termination, key: "code")
            context["termination"] = .object(termination)
        }
        if let sourceEvidence = sourceEvidence(
            diagnostic: raw,
            metadata: metadata,
            reportingSource: reportingSource,
            dataPolicy: dataPolicy
        ) {
            context["source_evidence"] = .object(sourceEvidence)
        }
        mergeSourceMetadata(metadata, diagnostic: raw, into: &context)
        if dataPolicy == .full, let rawValue = LogisterValue(jsonObject: raw) {
            context["metrickit"] = rawValue
        }
        return LogisterPrivacySanitizer.sanitize(context)
    }

    private static func sourceEvidence(
        diagnostic: [String: Any],
        metadata: [String: Any],
        reportingSource: [String: Any],
        dataPolicy: LogisterExceptionDataPolicy
    ) -> LogisterContext? {
        var diagnostic = diagnostic
        if dataPolicy != .full {
            diagnostic.removeValue(forKey: "terminationReason")
            diagnostic.removeValue(forKey: "exceptionReason")
        }
        var evidence: LogisterContext = [
            "format": .string("metrickit_json"),
            "decoder": .string("metrickit-legacy-v2")
        ]
        if let value = LogisterValue(jsonObject: diagnostic) { evidence["diagnostic"] = value }
        if let value = LogisterValue(jsonObject: metadata) { evidence["metadata"] = value }
        if let start = stringValue(LogisterValue(jsonObject: reportingSource["timeStampBegin"] as Any)),
           let end = stringValue(LogisterValue(jsonObject: reportingSource["timeStampEnd"] as Any)) {
            evidence["reporting_period"] = .object(["start": .string(start), "end": .string(end)])
        }
        return evidence
    }

    private static func mergeSourceMetadata(
        _ metadata: [String: Any],
        diagnostic: [String: Any],
        into context: inout LogisterContext
    ) {
        var app: LogisterContext = [:]
        put(diagnostic["applicationVersion"] ?? metadata["applicationVersion"], into: &app, key: "version_name")
        put(metadata["applicationBuildVersion"] ?? metadata["appBuildVersion"], into: &app, key: "version_code")
        if !app.isEmpty { context["app"] = .object(app) }

        var device: LogisterContext = [:]
        put(metadata["deviceType"], into: &device, key: "model_identifier")
        put(metadata["platformArchitecture"], into: &device, key: "architecture")
        if !device.isEmpty { context["device"] = .object(device) }

        var os: LogisterContext = [:]
        put(metadata["osVersion"], into: &os, key: "version")
        if !os.isEmpty { context["os"] = .object(os) }

        if let isTestFlight = metadata["isTestFlightApp"] as? Bool, isTestFlight {
            context["distribution"] = .object(["channel": .string("testflight")])
        }
    }

    private static func normalizedThreads(_ raw: [String: Any], kind: LogisterMetricKitDiagnosticKind) -> [LogisterValue] {
        let tree = (raw["callStackTree"] as? [String: Any]) ?? raw
        let stacks = tree["callStacks"] as? [[String: Any]] ?? []
        return stacks.prefix(maximumThreads).enumerated().map { index, stack in
            let roots = stack["callStackRootFrames"] as? [[String: Any]] ?? []
            let attributed = stack["threadAttributed"] as? Bool ?? false
            return .object([
                "id": .string(String(index)),
                "name": .string(threadName(kind, index: index)),
                "role": .string(threadRole(kind, index: index, attributed: attributed)),
                "attributed": .bool(attributed),
                "triggered": .bool(kind == .crash && attributed),
                "frames": .array(flatten(roots))
            ])
        }
    }

    private static func normalizedCallStackTree(
        _ raw: [String: Any],
        kind: LogisterMetricKitDiagnosticKind
    ) -> LogisterValue? {
        let tree = (raw["callStackTree"] as? [String: Any]) ?? raw
        let stacks = tree["callStacks"] as? [[String: Any]] ?? []
        guard !stacks.isEmpty else { return nil }

        let normalized = stacks.prefix(maximumThreads).enumerated().map { index, stack -> LogisterValue in
            let attributed = stack["threadAttributed"] as? Bool ?? false
            let roots = stack["callStackRootFrames"] as? [[String: Any]] ?? []
            var value: LogisterContext = [
                "id": .string(String(index)),
                "name": .string(threadName(kind, index: index)),
                "role": .string(threadRole(kind, index: index, attributed: attributed)),
                "attributed": .bool(attributed),
                "root_frames": .array(
                    roots.prefix(maximumFramesPerThread).map { normalizedTreeFrame($0, depth: 0) }
                )
            ]
            put(stack["sampleCount"], into: &value, key: "sample_count")
            return .object(value)
        }
        return .object([
            "per_thread": .bool(tree["callStackPerThread"] as? Bool ?? false),
            "stacks": .array(normalized)
        ])
    }

    private static func normalizedTreeFrame(_ frame: [String: Any], depth: Int) -> LogisterValue {
        let image = frame["binaryName"] as? String
        var value: LogisterContext = [
            "application_frame": .bool(isApplicationFrame(frame, image: image))
        ]
        put(image, into: &value, key: "image")
        put(frame["binaryUUID"], into: &value, key: "image_uuid")
        putAddress(frame["address"], into: &value, key: "address")
        putAddress(frame["offsetIntoBinaryTextSegment"], into: &value, key: "relative_address")
        put(frame["sampleCount"], into: &value, key: "sample_count")
        let children = frame["subFrames"] as? [[String: Any]] ?? []
        if !children.isEmpty, depth < maximumCallTreeDepth {
            value["subframes"] = .array(
                children.prefix(maximumFramesPerThread).map { normalizedTreeFrame($0, depth: depth + 1) }
            )
        }
        return .object(value)
    }

    private static func flatten(_ frames: [[String: Any]]) -> [LogisterValue] {
        var result: [LogisterValue] = []
        append(frames, to: &result)
        return result
    }

    private static func append(_ frames: [[String: Any]], to result: inout [LogisterValue]) {
        for frame in frames where result.count < maximumFramesPerThread {
            let image = frame["binaryName"] as? String
            var value: LogisterContext = [
                "application_frame": .bool(isApplicationFrame(frame, image: image))
            ]
            put(image, into: &value, key: "image")
            put(frame["binaryUUID"], into: &value, key: "image_uuid")
            putAddress(frame["address"], into: &value, key: "address")
            putAddress(frame["offsetIntoBinaryTextSegment"], into: &value, key: "relative_address")
            put(frame["sampleCount"], into: &value, key: "sample_count")
            result.append(.object(value))
            let children = frame["subFrames"] as? [[String: Any]] ?? []
            append(children, to: &result)
        }
    }

    private static func normalizedMeasurements(
        _ raw: [String: Any],
        kind: LogisterMetricKitDiagnosticKind
    ) -> LogisterContext {
        let definitions: [(String, [String], String, String)] = switch kind {
        case .hang:
            [("hang_duration", ["hangDuration", "duration"], "seconds", "time")]
        case .cpuException:
            [
                ("total_cpu_time", ["totalCPUTime", "totalCpuTime"], "seconds", "time"),
                ("sampled_time", ["totalSampledTime", "sampledTime"], "seconds", "time")
            ]
        case .diskWriteException:
            [("total_bytes_written", ["totalWritesCaused", "totalDiskWrites", "totalBytesWritten"], "bytes", "bytes")]
        case .launchFailure:
            [("launch_duration", ["launchDuration", "duration"], "seconds", "time")]
        case .crash, .memoryTermination:
            []
        }

        var result: LogisterContext = [:]
        for (key, sourceFields, canonicalUnit, dimension) in definitions {
            guard let sourceField = sourceFields.first(where: { raw[$0] != nil }),
                  let measurement = normalizedMeasurement(
                    raw[sourceField],
                    canonicalUnit: canonicalUnit,
                    dimension: dimension,
                    sourceField: sourceField
                  ) else { continue }
            result[key] = .object(measurement)
        }
        return result
    }

    private static func normalizedMeasurement(
        _ raw: Any?,
        canonicalUnit: String,
        dimension: String,
        sourceField: String
    ) -> LogisterContext? {
        guard let pair = measurementPair(raw) else { return nil }
        let value: Double?
        if dimension == "time" {
            value = timeInSeconds(pair.value, unit: pair.unit)
        } else {
            value = bytes(pair.value, unit: pair.unit)
        }
        guard let value, value.isFinite, value >= 0 else { return nil }
        return [
            "value": .number(value),
            "unit": .string(canonicalUnit),
            "source_field": .string(sourceField)
        ]
    }

    private static func measurementPair(_ raw: Any?) -> (value: Double, unit: String?)? {
        if let number = raw as? NSNumber {
            return (number.doubleValue, nil)
        }
        if let object = raw as? [String: Any] {
            let value = object["value"] ?? object["averageValue"] ?? object["doubleValue"]
            guard let number = measurementPair(value)?.value else { return nil }
            let unit = (object["unit"] ?? object["unitSymbol"]) as? String
            return (number, unit)
        }
        guard let string = raw as? String else { return nil }
        let pattern = #"^\s*([+-]?(?:\d+(?:\.\d+)?|\.\d+))\s*([^\s].*)?\s*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
              let valueRange = Range(match.range(at: 1), in: string),
              let value = Double(string[valueRange]) else { return nil }
        let unit = Range(match.range(at: 2), in: string).map { String(string[$0]).trimmingCharacters(in: .whitespaces) }
        return (value, unit?.isEmpty == true ? nil : unit)
    }

    private static func timeInSeconds(_ value: Double, unit: String?) -> Double? {
        switch unit?.lowercased().replacingOccurrences(of: " ", with: "") {
        case nil, "s", "sec", "secs", "second", "seconds": value
        case "ms", "msec", "millisecond", "milliseconds": value / 1_000
        case "us", "µs", "microsecond", "microseconds": value / 1_000_000
        case "ns", "nanosecond", "nanoseconds": value / 1_000_000_000
        case "min", "minute", "minutes": value * 60
        default: nil
        }
    }

    private static func bytes(_ value: Double, unit: String?) -> Double? {
        switch unit?.lowercased().replacingOccurrences(of: " ", with: "") {
        case nil, "b", "byte", "bytes": value
        case "kb": value * 1_000
        case "kib": value * 1_024
        case "mb": value * 1_000_000
        case "mib": value * 1_048_576
        case "gb": value * 1_000_000_000
        case "gib": value * 1_073_741_824
        default: nil
        }
    }

    private static func primaryThreadRole(_ kind: LogisterMetricKitDiagnosticKind) -> String {
        switch kind {
        case .crash: "crashed"
        case .hang: "main"
        case .cpuException, .diskWriteException, .launchFailure: "sampled"
        case .memoryTermination: "unknown"
        }
    }

    private static func threadRole(
        _ kind: LogisterMetricKitDiagnosticKind,
        index: Int,
        attributed: Bool
    ) -> String {
        switch kind {
        case .crash: attributed ? "crashed" : "thread"
        case .hang: index == 0 ? "main" : "sampled"
        case .cpuException, .diskWriteException, .launchFailure: "sampled"
        case .memoryTermination: "unknown"
        }
    }

    private static func threadName(_ kind: LogisterMetricKitDiagnosticKind, index: Int) -> String {
        kind == .hang && index == 0 ? "Main thread sample" : "Thread \(index)"
    }

    private static func putAddress(_ raw: Any?, into context: inout LogisterContext, key: String) {
        guard let value = hexadecimalAddress(raw) else { return }
        context[key] = .string(value)
    }

    private static func hexadecimalAddress(_ raw: Any?) -> String? {
        if let number = raw as? NSNumber {
            guard number.doubleValue.isFinite, number.doubleValue >= 0 else { return nil }
            return String(format: "0x%llx", number.uint64Value)
        }
        guard let string = raw as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: UInt64?
        if trimmed.lowercased().hasPrefix("0x") {
            value = UInt64(trimmed.dropFirst(2), radix: 16)
        } else {
            value = UInt64(trimmed, radix: 10) ?? Double(trimmed).flatMap { decimal in
                guard decimal.isFinite,
                      decimal >= 0,
                      decimal.rounded(.towardZero) == decimal,
                      decimal <= Double(UInt64.max) else { return nil }
                return UInt64(decimal)
            }
        }
        return value.map { String(format: "0x%llx", $0) }
    }

    private static func diagnosticSignature(
        kind: LogisterMetricKitDiagnosticKind,
        threads: [LogisterValue],
        raw: [String: Any]
    ) -> String? {
        for thread in threads {
            guard case .object(let threadValue) = thread,
                  case .array(let frames) = threadValue["frames"] else { continue }
            let isCulprit: Bool
            if case .bool(true) = threadValue["triggered"] {
                isCulprit = true
            } else if kind != .crash, case .bool(true) = threadValue["attributed"] {
                isCulprit = true
            } else {
                isCulprit = false
            }
            guard isCulprit else { continue }
            for frame in frames {
                guard case .object(let frameValue) = frame,
                      case .bool(true) = frameValue["application_frame"],
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

    private static func isApplicationFrame(_ frame: [String: Any], image: String?) -> Bool {
        (frame["applicationFrame"] as? Bool)
            ?? (frame["isApplicationFrame"] as? Bool)
            ?? (image == ProcessInfo.processInfo.processName)
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
@MainActor
public final class LogisterMetricKitCollector: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    private let client: LogisterClient
    private let dataPolicy: LogisterExceptionDataPolicy
    private let onUploadError: (@Sendable (String) -> Void)?
    private var started = false
    private var uploadTasks: [UUID: Task<Void, Never>] = [:]

    public init(
        client: LogisterClient,
        onUploadError: (@Sendable (String) -> Void)? = nil
    ) {
        self.client = client
        self.dataPolicy = .typeAndStacktrace
        self.onUploadError = onUploadError
    }

    public init(
        client: LogisterClient,
        dataPolicy: LogisterExceptionDataPolicy,
        onUploadError: (@Sendable (String) -> Void)? = nil
    ) {
        self.client = client
        self.dataPolicy = dataPolicy
        self.onUploadError = onUploadError
    }

    public func start() {
        guard !started else { return }
        started = true
        MXMetricManager.shared.add(self)
        Task { await client.setMetricKitSubscribed(true) }
    }

    public func stop() {
        guard started else { return }
        MXMetricManager.shared.remove(self)
        started = false
        uploadTasks.values.forEach { $0.cancel() }
        uploadTasks.removeAll()
        Task { await client.setMetricKitSubscribed(false) }
    }

    nonisolated public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        var deliveries: [(Data, LogisterMetricKitDiagnosticKind, Data)] = []
        for payload in payloads {
            let sourcePayload = payload.jsonRepresentation()
            payload.crashDiagnostics?.forEach { deliveries.append(($0.jsonRepresentation(), .crash, sourcePayload)) }
            payload.hangDiagnostics?.forEach { deliveries.append(($0.jsonRepresentation(), .hang, sourcePayload)) }
            payload.cpuExceptionDiagnostics?.forEach { deliveries.append(($0.jsonRepresentation(), .cpuException, sourcePayload)) }
            payload.diskWriteExceptionDiagnostics?.forEach { deliveries.append(($0.jsonRepresentation(), .diskWriteException, sourcePayload)) }
            #if os(iOS)
            if #available(iOS 16.0, *) {
                payload.appLaunchDiagnostics?.forEach { deliveries.append(($0.jsonRepresentation(), .launchFailure, sourcePayload)) }
            }
            #endif
        }
        Task { @MainActor [weak self] in
            deliveries.forEach { self?.upload($0.0, kind: $0.1, sourcePayload: $0.2) }
        }
    }

    private func upload(_ data: Data, kind: LogisterMetricKitDiagnosticKind, sourcePayload: Data) {
        let taskID = UUID()
        uploadTasks[taskID] = Task { [weak self, client, dataPolicy, onUploadError] in
            do {
                try await client.captureMetricKitDiagnostic(
                    data,
                    kind: kind,
                    dataPolicy: dataPolicy,
                    sourcePayload: sourcePayload
                )
            } catch {
                onUploadError?(String(describing: error))
            }
            _ = await MainActor.run { self?.uploadTasks.removeValue(forKey: taskID) }
        }
    }
}
#endif
