import Foundation

public typealias LogisterBeforeSend = @Sendable (LogisterContext) -> LogisterContext?

public enum LogisterCollectionCategory: String, CaseIterable, Hashable, Sendable {
    case errors
    case logs
    case metrics
    case performance
    case checkIns = "check_ins"
    case metricKit = "metrickit"
    case identity
}

/// Deterministic privacy and payload limits applied before persistence or transport.
public struct LogisterPayloadPolicy: Sendable {
    public var maximumDepth: Int
    public var maximumItems: Int
    public var maximumStringLength: Int
    public var maximumEnvelopeBytes: Int
    public var sensitiveKeys: Set<String>

    public init(
        maximumDepth: Int = 12,
        maximumItems: Int = 1_000,
        maximumStringLength: Int = 4_096,
        maximumEnvelopeBytes: Int = 2_500_000,
        sensitiveKeys: Set<String> = LogisterPayloadPolicy.defaultSensitiveKeys
    ) {
        self.maximumDepth = min(max(maximumDepth, 2), 32)
        self.maximumItems = min(max(maximumItems, 10), 10_000)
        self.maximumStringLength = min(max(maximumStringLength, 128), 32_768)
        self.maximumEnvelopeBytes = min(max(maximumEnvelopeBytes, 16 * 1_024), 4 * 1_024 * 1_024)
        self.sensitiveKeys = Set(sensitiveKeys.map(Self.normalizedKey))
    }

    public static let `default` = LogisterPayloadPolicy()

    public static let defaultSensitiveKeys: Set<String> = [
        "password", "passwd", "secret", "authorization", "cookie", "set_cookie",
        "access_token", "auth_token", "token", "refresh_token", "api_key",
        "client_secret", "credential", "credentials"
    ]

    static func normalizedKey(_ key: String) -> String {
        key.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "_" }
            .reduce(into: "") { result, character in
                if character != "_" || result.last != "_" { result.append(character) }
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }
}

/// Durable delivery, consent, identity, and final-processing configuration.
public struct LogisterConfiguration: Sendable {
    public var collectionEnabled: Bool
    public var enabledCategories: Set<LogisterCollectionCategory>
    public var storageScope: String?
    public var storageDirectory: URL?
    public var maximumQueuedEvents: Int
    public var maximumQueueBytes: Int
    public var maximumQueueAge: TimeInterval
    public var installationTrackingEnabled: Bool
    public var installationRotationInterval: TimeInterval
    public var payloadPolicy: LogisterPayloadPolicy
    public var beforeSend: LogisterBeforeSend?

    public init(
        collectionEnabled: Bool = true,
        enabledCategories: Set<LogisterCollectionCategory> = Set(LogisterCollectionCategory.allCases),
        storageScope: String? = nil,
        storageDirectory: URL? = nil,
        maximumQueuedEvents: Int = 50,
        maximumQueueBytes: Int = 10 * 1_024 * 1_024,
        maximumQueueAge: TimeInterval = 7 * 24 * 60 * 60,
        installationTrackingEnabled: Bool = false,
        installationRotationInterval: TimeInterval = 90 * 24 * 60 * 60,
        payloadPolicy: LogisterPayloadPolicy = .default,
        beforeSend: LogisterBeforeSend? = nil
    ) {
        self.collectionEnabled = collectionEnabled
        self.enabledCategories = enabledCategories
        self.storageScope = storageScope?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.storageDirectory = storageDirectory
        self.maximumQueuedEvents = min(max(maximumQueuedEvents, 1), 500)
        self.maximumQueueBytes = min(max(maximumQueueBytes, 64 * 1_024), 50 * 1_024 * 1_024)
        self.maximumQueueAge = min(max(maximumQueueAge, 60), 30 * 24 * 60 * 60)
        self.installationTrackingEnabled = installationTrackingEnabled
        self.installationRotationInterval = min(max(installationRotationInterval, 24 * 60 * 60), 365 * 24 * 60 * 60)
        self.payloadPolicy = payloadPolicy
        self.beforeSend = beforeSend
    }

    public static let `default` = LogisterConfiguration()
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
