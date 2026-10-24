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
///
/// The defaults match the Logister server's per-event limits so a bounded event
/// is never rejected for size. When a budget runs out the SDK keeps every
/// envelope field, drops the remaining context, and sets `context._truncated`.
public struct LogisterPayloadPolicy: Sendable {
    public var maximumDepth: Int
    public var maximumItems: Int
    public var maximumStringLength: Int
    public var maximumEnvelopeBytes: Int
    /// Object keys allowed across the whole event, envelope included.
    public var maximumKeys: Int
    /// Keys whose values become `[REDACTED]`, compared after lowercasing and
    /// removing every non-alphanumeric character. Union your own keys with
    /// `defaultSensitiveKeys` to extend the list.
    public var sensitiveKeys: Set<String> {
        didSet { sensitiveKeys = Set(sensitiveKeys.map(Self.normalizedKey)) }
    }

    public init(
        maximumDepth: Int = 12,
        maximumItems: Int = 1_000,
        maximumStringLength: Int = 4_096,
        maximumEnvelopeBytes: Int = 1_000_000,
        sensitiveKeys: Set<String> = LogisterPayloadPolicy.defaultSensitiveKeys
    ) {
        self.maximumDepth = min(max(maximumDepth, 2), 32)
        self.maximumItems = min(max(maximumItems, 10), 10_000)
        self.maximumStringLength = min(max(maximumStringLength, 128), 32_768)
        self.maximumEnvelopeBytes = min(max(maximumEnvelopeBytes, 16 * 1_024), 4 * 1_024 * 1_024)
        self.maximumKeys = 512
        self.sensitiveKeys = Set(sensitiveKeys.map(Self.normalizedKey))
    }

    public static let `default` = LogisterPayloadPolicy()

    /// The exact-match half of the shared Logister redaction rule.
    public static let defaultSensitiveKeys: Set<String> = [
        "password", "passwd", "pwd", "secret", "token", "apikey", "authorization",
        "proxyauthorization", "cookie", "setcookie", "sessiontoken", "sessionkey",
        "credential", "credentials", "privatekey", "clientsecret", "accesstoken",
        "refreshtoken", "idtoken", "authtoken", "xapikey", "xauthtoken", "xaccesstoken",
        "xcsrftoken", "xxsrftoken", "signature", "ssn", "creditcard", "cardnumber", "cvv"
    ]

    /// The contains-match half of the shared rule. It always applies.
    static let sensitiveKeyFragments = [
        "token", "secret", "password", "passwd", "apikey", "authorization", "credential", "cookie"
    ]

    static func normalizedKey(_ key: String) -> String {
        key.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    func isSensitiveKey(_ key: String) -> Bool {
        let normalized = Self.normalizedKey(key)
        return sensitiveKeys.contains(normalized)
            || Self.sensitiveKeyFragments.contains { normalized.contains($0) }
    }

    var effectiveMaximumKeys: Int {
        min(max(maximumKeys, 64), 10_000)
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
    /// Seconds to wait for `LogisterTokenProvider.fetchToken()` before the
    /// delivery attempt fails and the event stays queued. Clamped to 1...120.
    public var tokenProviderTimeout: TimeInterval = 30
    /// Permits a plain `http` endpoint on a non-loopback host. Use it only for
    /// local development servers; the bearer token is sent in clear text.
    public var allowsInsecureTransport = false

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
