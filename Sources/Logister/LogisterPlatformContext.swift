import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum LogisterSDK {
    static let name = "logister-ios"
    static let version = "0.3.0"
    static let telemetrySchemaVersion = 2
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
    private static let disallowedKeys: Set<String> = [
        "advertisingid", "advertisingidentifier", "idfa", "idfv",
        "identifierforvendor", "serial", "serialnumber", "deviceserial",
        "hardwareid", "hardwareserial", "androidid", "imei", "meid",
        "subscriberid"
    ]

    static func sanitize(_ context: LogisterContext) -> LogisterContext {
        context.reduce(into: LogisterContext()) { result, entry in
            let normalized = entry.key.lowercased().filter { $0.isLetter || $0.isNumber }
            guard !disallowedKeys.contains(normalized) else { return }
            result[entry.key] = sanitize(entry.value)
        }
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
