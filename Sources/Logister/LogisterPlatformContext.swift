import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum LogisterSDK {
    static let name = "logister-ios"
    static let version = "0.7.0"
    static let telemetrySchemaVersion = 3
}

enum LogisterPlatformContext {
    static var applePlatform: String {
        #if os(visionOS)
        return "visionos"
        #elseif os(iOS)
        return "ios"
        #elseif os(macOS)
        return "macos"
        #elseif os(tvOS)
        return "tvos"
        #elseif os(watchOS)
        return "watchos"
        #else
        return "apple"
        #endif
    }

    static var osName: String {
        switch applePlatform {
        case "ios": "iOS"
        case "macos": "macOS"
        case "tvos": "tvOS"
        case "watchos": "watchOS"
        case "visionos": "visionOS"
        default: "Apple OS"
        }
    }

    static var osVersion: String {
        let value = ProcessInfo.processInfo.operatingSystemVersion
        return "\(value.majorVersion).\(value.minorVersion).\(value.patchVersion)"
    }

    static var deviceFamily: String {
        switch applePlatform {
        case "ios":
            let model = machineModel ?? ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]
            if model?.hasPrefix("iPad") == true { return "iPad" }
            if model?.hasPrefix("iPhone") == true { return "iPhone" }
            if model?.hasPrefix("iPod") == true { return "iPod touch" }
            return "iPhone or iPad"
        case "macos": return "Mac"
        case "tvos": return "Apple TV"
        case "watchos": return "Apple Watch"
        case "visionos": return "Apple Vision"
        default: return "Apple device"
        }
    }

    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #elseif arch(arm)
        return "arm"
        #else
        return "unknown"
        #endif
    }

    static var machineModel: String? {
        #if canImport(Darwin)
        var value = utsname()
        guard uname(&value) == 0 else { return nil }
        var machine = value.machine
        let capacity = MemoryLayout.size(ofValue: machine)
        return withUnsafePointer(to: &machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                String(cString: $0)
            }
        }
        #else
        return nil
        #endif
    }

    static var osBuild: String? {
        #if canImport(Darwin)
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
        #else
        return nil
        #endif
    }

    static func context(
        service: String?,
        policy: LogisterPlatformContextPolicy = .standard
    ) -> LogisterContext {
        let bundle = Bundle.main
        let identifier = bundle.bundleIdentifier ?? service
        let versionName = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let versionCode = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        var app: LogisterContext = [
            "process": .string(ProcessInfo.processInfo.processName)
        ]
        put(identifier, into: &app, key: "identifier")
        put(versionName, into: &app, key: "version_name")
        put(versionCode, into: &app, key: "version_code")

        var device: LogisterContext = ["family": .string(deviceFamily)]
        if policy == .standard {
            device["architecture"] = .string(architecture)
            device["locale"] = .string(Locale.current.identifier)
            put(machineModel, into: &device, key: "model")
        }

        var os: LogisterContext = [
            "name": .string(osName),
            "version": .string(osVersion)
        ]
        if policy == .standard {
            put(osBuild, into: &os, key: "build")
        }

        return [
            "telemetry_schema_version": .number(Double(LogisterSDK.telemetrySchemaVersion)),
            "platform": .string("ios"),
            "apple_platform": .string(applePlatform),
            "app": .object(app),
            "device": .object(device),
            "os": .object(os),
            "sdk": .object([
                "name": .string(LogisterSDK.name),
                "version": .string(LogisterSDK.version),
                "platform_context_policy": .string(policy.rawValue)
            ])
        ]
    }

    static var inferredRelease: String? {
        let bundle = Bundle.main
        guard let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !version.isEmpty else { return nil }
        guard let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              !build.isEmpty else { return version }
        return "\(version)+\(build)"
    }

    private static func put(_ value: String?, into context: inout LogisterContext, key: String) {
        guard let value, !value.isEmpty else { return }
        context[key] = .string(value)
    }
}

enum LogisterPrivacySanitizer {
    static let redacted = "[REDACTED]"
    static let truncationKey = "_truncated"
    // Mirrors the Logister server's TelemetryPayloadLimits.
    static let maximumArrayLength = 1_000
    static let maximumMessageLength = 16_384

    private static let disallowedKeys: Set<String> = [
        "advertisingid", "advertisingidentifier", "idfa", "idfv",
        "identifierforvendor", "serial", "serialnumber", "deviceserial",
        "hardwareid", "hardwareserial", "androidid", "imei", "meid",
        "subscriberid"
    ]
    /// Top-level fields owned by the SDK envelope. They are kept whatever the
    /// budget and are never treated as sensitive keys.
    static let envelopeKeys: Set<String> = [
        "uuid", "event_type", "message", "level", "fingerprint", "environment", "release",
        "occurred_at", "trace_id", "request_id", "session_id", "user_id", "transaction_name",
        "duration_ms", "evidence", "context"
    ]
    /// Identifier values the SDK generates; they are bounded but not scrubbed.
    private static let identifierKeys: Set<String> = [
        "uuid", "event_type", "occurred_at", "trace_id", "request_id", "session_id"
    ]

    /// SDK-owned context that identifies the event; kept before caller context.
    private static let priorityContextKeys: Set<String> = [
        "telemetry_schema_version", "platform", "apple_platform", "sdk", "app", "os", "device",
        "error", "diagnostic", "exception", "termination", "symbolication", "environment",
        "release", "trace_id", "request_id", "span_id", "session", "installation"
    ]

    private struct Budget {
        var items: Int
        var keys: Int
        var maximumStringLength: Int
        var truncated = false
    }

    static func sanitize(_ context: LogisterContext) -> LogisterContext {
        context.reduce(into: LogisterContext()) { result, entry in
            guard !isDisallowed(entry.key) else { return }
            result[entry.key] = sanitize(entry.value)
        }
    }

    /// Applies redaction and the payload budgets. `scale` divides the budgets
    /// so a caller can shrink an event that still exceeds the byte limit.
    static func sanitizePayload(
        _ payload: LogisterContext,
        policy: LogisterPayloadPolicy,
        scale: Int = 1
    ) -> LogisterContext {
        let scale = max(scale, 1)
        var budget = Budget(
            items: policy.maximumItems / scale,
            keys: policy.effectiveMaximumKeys / scale,
            maximumStringLength: max(policy.maximumStringLength / scale, 128),
            truncated: scale > 1
        )
        var result: LogisterContext = [:]
        for key in payload.keys.sorted() where envelopeKeys.contains(key) && key != "context" {
            guard let value = payload[key] else { continue }
            // Envelope fields are never shortened by the budget, but their keys
            // still count toward the event total the server enforces.
            var fieldBudget = Budget(
                items: policy.maximumItems,
                keys: policy.effectiveMaximumKeys,
                maximumStringLength: budget.maximumStringLength
            )
            result[key] = sanitizeEnvelopeField(key, value, policy: policy, budget: &fieldBudget)
            budget.keys -= 1 + policy.effectiveMaximumKeys - fieldBudget.keys
        }

        // Reserve the context key and its truncation marker.
        budget.keys -= 2
        budget.items = policy.maximumItems / scale
        let attributes = payload.filter { !envelopeKeys.contains($0.key) }
        for (key, value) in sanitizeObject(attributes, policy: policy, budget: &budget, depth: 0, parentKey: nil) {
            result[key] = value
        }

        budget.items = policy.maximumItems / scale
        var context: LogisterValue?
        if let value = payload["context"] {
            context = sanitizeValue(value, policy: policy, budget: &budget, depth: 1, parentKey: "context")
            if context == nil { budget.truncated = true }
        }
        if budget.truncated {
            var object: LogisterContext = [:]
            if case .object(let existing) = context { object = existing }
            object[truncationKey] = .bool(true)
            context = .object(object)
        }
        result["context"] = context
        return result
    }

    private static func sanitizeEnvelopeField(
        _ key: String,
        _ value: LogisterValue,
        policy: LogisterPayloadPolicy,
        budget: inout Budget
    ) -> LogisterValue {
        guard case .string(let string) = value else {
            return sanitizeValue(value, policy: policy, budget: &budget, depth: 1, parentKey: key) ?? .null
        }
        if identifierKeys.contains(key) { return .string(bounded(string, maximumLength: 256)) }
        let limit = key == "message"
            ? min(budget.maximumStringLength, maximumMessageLength)
            : budget.maximumStringLength
        return .string(scrub(string, maximumLength: limit))
    }

    /// Scalars are kept before containers and small containers before large
    /// ones, so a large stack or breadcrumb list cannot crowd out the platform,
    /// SDK and error facts that identify the event.
    private static func sanitizeObject(
        _ object: LogisterContext,
        policy: LogisterPayloadPolicy,
        budget: inout Budget,
        depth: Int,
        parentKey: String?
    ) -> LogisterContext {
        var result: LogisterContext = [:]
        let entries = object.filter { !isDisallowed($0.key) }
        let weightLimit = max(budget.items, budget.keys) + 1
        let order: [String]
        if parentKey == "context", depth == 1 {
            let priority = entries.filter { priorityContextKeys.contains($0.key) }
            let rest = entries.filter { !priorityContextKeys.contains($0.key) }
            order = budgetOrder(priority, weightLimit: weightLimit) + budgetOrder(rest, weightLimit: weightLimit)
        } else {
            order = budgetOrder(entries, weightLimit: weightLimit)
        }
        for key in order {
            guard budget.items > 0, budget.keys > 0 else {
                budget.truncated = true
                break
            }
            guard let value = entries[key] else { continue }
            budget.items -= 1
            budget.keys -= 1
            if isSensitive(key, parentKey: parentKey, policy: policy) {
                result[key] = .string(redacted)
                continue
            }
            guard let sanitized = sanitizeValue(value, policy: policy, budget: &budget, depth: depth + 1, parentKey: key) else {
                // A leaf object that no longer fits is dropped whole rather than split.
                budget.items += 1
                budget.keys += 1
                budget.truncated = true
                break
            }
            result[key] = sanitized
        }
        return result
    }

    private static func sanitizeValue(
        _ value: LogisterValue,
        policy: LogisterPayloadPolicy,
        budget: inout Budget,
        depth: Int,
        parentKey: String?
    ) -> LogisterValue? {
        switch value {
        case .object(let object):
            guard depth < policy.maximumDepth else {
                budget.truncated = true
                guard budget.keys > 0 else { return .object([:]) }
                budget.keys -= 1
                return .object([truncationKey: .bool(true)])
            }
            if object.values.allSatisfy({ !isContainer($0) }) {
                let count = object.keys.filter { !isDisallowed($0) }.count
                guard count <= budget.items, count <= budget.keys else { return nil }
            }
            return .object(sanitizeObject(object, policy: policy, budget: &budget, depth: depth, parentKey: parentKey))
        case .array(let values):
            guard depth < policy.maximumDepth else {
                budget.truncated = true
                return .array([.string("[TRUNCATED]")])
            }
            // Breadcrumbs are oldest first; when they do not all fit keep the newest.
            let newestFirst = parentKey == "breadcrumbs"
            var result: [LogisterValue] = []
            for value in newestFirst ? Array(values.suffix(maximumArrayLength).reversed()) : Array(values.prefix(maximumArrayLength)) {
                guard budget.items > 0 else {
                    budget.truncated = true
                    break
                }
                budget.items -= 1
                guard let sanitized = sanitizeValue(value, policy: policy, budget: &budget, depth: depth + 1, parentKey: parentKey) else {
                    budget.items += 1
                    budget.truncated = true
                    break
                }
                result.append(sanitized)
            }
            if values.count > maximumArrayLength { budget.truncated = true }
            return .array(newestFirst ? result.reversed() : result)
        case .string(let string):
            return .string(scrub(string, maximumLength: budget.maximumStringLength))
        case .number(let number):
            // JSONSerialization raises an Objective-C exception for NaN and infinity.
            return number.isFinite ? value : .null
        default:
            return value
        }
    }

    private static func budgetOrder(_ entries: LogisterContext, weightLimit: Int) -> [String] {
        let scalars = entries.filter { !isContainer($0.value) }.map(\.key).sorted()
        let weighted: [(key: String, weight: Int)] = entries.compactMap { entry in
            isContainer(entry.value) ? (entry.key, weight(entry.value, limit: weightLimit)) : nil
        }
        let containers = weighted.sorted { lhs, rhs in
            lhs.weight == rhs.weight ? lhs.key < rhs.key : lhs.weight < rhs.weight
        }.map(\.key)
        return scalars + containers
    }

    private static func isSensitive(_ key: String, parentKey: String?, policy: LogisterPayloadPolicy) -> Bool {
        // The MetricKit adapter's own grouping signature is not a credential.
        if key == "signature", parentKey == "diagnostic" { return false }
        return policy.isSensitiveKey(key)
    }

    private static func isDisallowed(_ key: String) -> Bool {
        disallowedKeys.contains(LogisterPayloadPolicy.normalizedKey(key))
    }

    private static func isContainer(_ value: LogisterValue) -> Bool {
        switch value {
        case .object, .array: true
        default: false
        }
    }

    private static func weight(_ value: LogisterValue, limit: Int) -> Int {
        var total = 0
        var pending = [value]
        while let next = pending.popLast(), total <= limit {
            switch next {
            case .object(let object):
                total += object.count
                pending.append(contentsOf: object.values)
            case .array(let values):
                total += values.count
                pending.append(contentsOf: values)
            default:
                break
            }
        }
        return total
    }

    private static let bearerExpression = try? NSRegularExpression(pattern: #"\b(bearer)\s+[^\s"',;]+"#, options: [.caseInsensitive])
    private static let basicExpression = try? NSRegularExpression(pattern: #"\b(basic)\s+([A-Za-z0-9+/]{4,}={0,2})"#, options: [.caseInsensitive])
    private static let urlExpression = try? NSRegularExpression(pattern: #"https?://[^\s"'<>]+"#, options: [.caseInsensitive])
    private static let jwtExpression = try? NSRegularExpression(pattern: #"\beyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#)
    private static let logisterKeyExpression = try? NSRegularExpression(pattern: #"\blgst_[A-Za-z0-9_-]+"#)

    static func scrub(_ value: String, maximumLength: Int) -> String {
        var result = value
        replaceMatches(of: bearerExpression, in: &result) { match, string in
            "\(substring(string, match.range(at: 1))) \(redacted)"
        }
        replaceMatches(of: basicExpression, in: &result) { match, string in
            // Only a base64 `user:password` pair is a Basic credential; this keeps
            // ordinary prose such as "basic setup" readable.
            let encoded = substring(string, match.range(at: 2))
            guard let decoded = Data(base64Encoded: encoded).flatMap({ String(data: $0, encoding: .utf8) }),
                  decoded.contains(":") else { return nil }
            return "\(substring(string, match.range(at: 1))) \(redacted)"
        }
        replaceMatches(of: urlExpression, in: &result) { match, string in
            guard var components = URLComponents(string: substring(string, match.range)) else { return nil }
            components.user = nil
            components.password = nil
            components.query = nil
            components.fragment = nil
            return components.string
        }
        replaceMatches(of: jwtExpression, in: &result) { _, _ in redacted }
        replaceMatches(of: logisterKeyExpression, in: &result) { _, _ in redacted }
        return bounded(result, maximumLength: maximumLength)
    }

    private static func replaceMatches(
        of expression: NSRegularExpression?,
        in string: inout String,
        replacement: (NSTextCheckingResult, String) -> String?
    ) {
        guard let expression else { return }
        let matches = expression.matches(in: string, range: NSRange(string.startIndex..., in: string))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: string),
                  let replacement = replacement(match, string) else { continue }
            string.replaceSubrange(range, with: replacement)
        }
    }

    private static func substring(_ string: String, _ range: NSRange) -> String {
        Range(range, in: string).map { String(string[$0]) } ?? ""
    }

    private static func bounded(_ value: String, maximumLength: Int) -> String {
        guard value.count > maximumLength else { return value }
        return String(value.prefix(maximumLength)) + "…"
    }

    /// Returns the JSON size, or nil when the value cannot be serialized.
    /// `JSONSerialization` raises instead of throwing for invalid input, so
    /// validity is always checked first.
    static func serializedSize(_ object: Any) -> Int? {
        guard JSONSerialization.isValidJSONObject(object) else { return nil }
        return try? JSONSerialization.data(withJSONObject: object).count
    }

    private static func sanitize(_ value: LogisterValue) -> LogisterValue {
        switch value {
        case .object(let object):
            return .object(sanitize(object))
        case .array(let values):
            return .array(values.map(sanitize))
        default:
            return value
        }
    }
}

enum LogisterStackFrameParser {
    private static let maximumFrames = 100

    static func frames(from symbols: [String], applicationImage: String?) -> [LogisterValue] {
        symbols.prefix(maximumFrames).enumerated().map { index, raw in
            let components = raw.split(maxSplits: 3, whereSeparator: \Character.isWhitespace).map(String.init)
            let image = components.count > 1 ? components[1] : nil
            let address = components.count > 2 && components[2].hasPrefix("0x") ? components[2] : nil
            let symbol = components.count > 3 ? components[3] : raw
            let isApplicationFrame = applicationFrame(image: image, applicationImage: applicationImage)

            var frame: LogisterContext = [
                "index": .number(Double(index)),
                "raw": .string(raw),
                "symbol": .string(symbol),
                "application_frame": .bool(isApplicationFrame)
            ]
            if let image { frame["image"] = .string(image) }
            if let address { frame["address"] = .string(address) }
            return .object(frame)
        }
    }

    private static func applicationFrame(image: String?, applicationImage: String?) -> Bool {
        guard let image, !image.isEmpty else { return false }
        if let applicationImage, image == applicationImage { return true }

        let frameworkPrefixes = [
            "lib", "Foundation", "CoreFoundation", "UIKitCore", "AppKit",
            "Swift", "XCTest", "dyld", "Dispatch", "CoreFoundation"
        ]
        return !frameworkPrefixes.contains { image.hasPrefix($0) }
    }
}
