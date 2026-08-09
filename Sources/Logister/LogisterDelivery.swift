import CryptoKit
import Foundation

public enum LogisterDeliveryState: String, Equatable, Sendable {
    case accepted
    case queued
    case rejected
    case dropped
}

public struct LogisterClientHealth: Equatable, Sendable {
    public var collectionEnabled: Bool
    public var queuedEventCount: Int
    public var discardedEventCount: Int
    public var lastDeliveryAt: Date?
    public var lastError: String?
    public var metricKitSubscribed: Bool
    public var sourceDecoder: String
    public var installationTrackingEnabled: Bool
    public var enabledCategories: Set<LogisterCollectionCategory>

    public init(
        collectionEnabled: Bool,
        queuedEventCount: Int,
        discardedEventCount: Int,
        lastDeliveryAt: Date?,
        lastError: String?,
        metricKitSubscribed: Bool,
        sourceDecoder: String,
        installationTrackingEnabled: Bool,
        enabledCategories: Set<LogisterCollectionCategory>
    ) {
        self.collectionEnabled = collectionEnabled
        self.queuedEventCount = queuedEventCount
        self.discardedEventCount = discardedEventCount
        self.lastDeliveryAt = lastDeliveryAt
        self.lastError = lastError
        self.metricKitSubscribed = metricKitSubscribed
        self.sourceDecoder = sourceDecoder
        self.installationTrackingEnabled = installationTrackingEnabled
        self.enabledCategories = enabledCategories
    }
}

struct LogisterCaptureState: Sendable {
    var collectionEnabled: Bool
    var installationIDHash: String?
    var identityEnabled: Bool
}

private struct QueuedEnvelope: Codable, Sendable {
    var id: UUID
    var capturedAt: Date
    var body: Data
    var attemptCount: Int
    var nextAttemptAt: Date?
    var priority: Int
}

private struct PersistedQueue: Codable, Sendable {
    var schemaVersion: Int
    var entries: [QueuedEnvelope]
}

private struct PersistedInstallation: Codable, Sendable {
    var idHash: String
    var createdAt: Date
}

actor LogisterRuntime {
    typealias Sender = @Sendable (Data) async throws -> LogisterResponse

    private let configuration: LogisterConfiguration
    private let queueURL: URL
    private let installationURL: URL
    private var collectionEnabled: Bool
    private var queue: [QueuedEnvelope]
    private var installation: PersistedInstallation?
    private var discardedEventCount = 0
    private var lastDeliveryAt: Date?
    private var lastError: String?
    private var metricKitSubscribed = false
    private var flushing = false

    init(endpoint: URL, service: String?, configuration: LogisterConfiguration) {
        self.configuration = configuration
        self.collectionEnabled = configuration.collectionEnabled
        let directory = configuration.storageDirectory ?? Self.defaultStorageDirectory()
        let scope = Self.storageScope(endpoint: endpoint, service: service, explicit: configuration.storageScope)
        self.queueURL = directory.appendingPathComponent("delivery-\(scope).json", isDirectory: false)
        self.installationURL = directory.appendingPathComponent("installation-\(scope).json", isDirectory: false)
        self.queue = Self.loadQueue(from: queueURL, configuration: configuration)
        self.installation = Self.loadInstallation(from: installationURL)
        Self.excludeFromBackup(directory)
    }

    func captureState(now: Date, category: LogisterCollectionCategory) -> LogisterCaptureState {
        let categoryEnabled = configuration.enabledCategories.contains(category)
        let identityEnabled = configuration.enabledCategories.contains(.identity)
        guard collectionEnabled, categoryEnabled else {
            return LogisterCaptureState(collectionEnabled: false, installationIDHash: nil, identityEnabled: false)
        }
        guard configuration.installationTrackingEnabled, identityEnabled else {
            return LogisterCaptureState(collectionEnabled: true, installationIDHash: nil, identityEnabled: identityEnabled)
        }
        if installation == nil || now.timeIntervalSince(installation!.createdAt) >= configuration.installationRotationInterval {
            installation = PersistedInstallation(
                idHash: Self.sha256(UUID().uuidString),
                createdAt: now
            )
            persistInstallation()
        }
        return LogisterCaptureState(collectionEnabled: true, installationIDHash: installation?.idHash, identityEnabled: identityEnabled)
    }

    func enqueueAndDrain(
        id: UUID,
        capturedAt: Date,
        body: Data,
        priority: Int,
        retryPolicy: LogisterRetryPolicy,
        sender: Sender
    ) async -> LogisterResponse {
        guard collectionEnabled else { return .dropped("collection disabled") }
        guard body.count <= configuration.payloadPolicy.maximumEnvelopeBytes else {
            discardedEventCount += 1
            lastError = "payload budget exceeded"
            return .dropped("payload budget exceeded")
        }
        pruneExpired(now: capturedAt)
        if !queue.contains(where: { $0.id == id }) {
            queue.append(
                QueuedEnvelope(
                    id: id,
                    capturedAt: capturedAt,
                    body: body,
                    attemptCount: 0,
                    nextAttemptAt: nil,
                    priority: priority
                )
            )
            enforceQueueBounds()
            guard queue.contains(where: { $0.id == id }), persistQueue() else {
                discardedEventCount += 1
                lastError = "durable queue write failed"
                return .dropped("durable queue write failed")
            }
        }
        return await drain(targetID: id, retryPolicy: retryPolicy, sender: sender).response
    }

    func flush(retryPolicy: LogisterRetryPolicy, force: Bool, sender: Sender) async -> Int {
        if force {
            for index in queue.indices { queue[index].nextAttemptAt = nil }
            _ = persistQueue()
        }
        return await drain(targetID: nil, retryPolicy: retryPolicy, sender: sender).acceptedCount
    }

    func setCollectionEnabled(_ enabled: Bool, purgeOnDisable: Bool) {
        collectionEnabled = enabled
        guard !enabled, purgeOnDisable else { return }
        queue.removeAll()
        installation = nil
        _ = try? FileManager.default.removeItem(at: queueURL)
        _ = try? FileManager.default.removeItem(at: installationURL)
    }

    func setMetricKitSubscribed(_ subscribed: Bool) {
        metricKitSubscribed = subscribed
    }

    func recordDiscard(reason: String) {
        discardedEventCount += 1
        lastError = String(reason.prefix(160))
    }

    func health() -> LogisterClientHealth {
        LogisterClientHealth(
            collectionEnabled: collectionEnabled,
            queuedEventCount: queue.count,
            discardedEventCount: discardedEventCount,
            lastDeliveryAt: lastDeliveryAt,
            lastError: lastError,
            metricKitSubscribed: metricKitSubscribed,
            sourceDecoder: "metrickit-legacy-v2",
            installationTrackingEnabled: configuration.installationTrackingEnabled,
            enabledCategories: configuration.enabledCategories
        )
    }

    private func drain(
        targetID: UUID?,
        retryPolicy: LogisterRetryPolicy,
        sender: Sender
    ) async -> (response: LogisterResponse, acceptedCount: Int) {
        guard collectionEnabled else { return (.dropped("collection disabled"), 0) }
        guard !flushing else { return (.queued(), 0) }
        flushing = true
        defer { flushing = false }
        var acceptedCount = 0
        var targetResponse: LogisterResponse?

        while collectionEnabled {
            let now = Date()
            guard let current = queue.first(where: { $0.nextAttemptAt == nil || $0.nextAttemptAt! <= now }) else {
                return (targetResponse ?? .queued(), acceptedCount)
            }
            do {
                let response = try await sender(current.body)
                guard let index = queue.firstIndex(where: { $0.id == current.id }) else { continue }
                if response.accepted {
                    queue.remove(at: index)
                    _ = persistQueue()
                    acceptedCount += 1
                    lastDeliveryAt = Date()
                    lastError = nil
                    if current.id == targetID { targetResponse = response.withDeliveryState(.accepted) }
                    continue
                }
                if retryPolicy.shouldRetry(statusCode: response.statusCode) {
                    scheduleRetry(at: index, policy: retryPolicy, response: response)
                    return (.queued(), acceptedCount)
                }
                queue.remove(at: index)
                discardedEventCount += 1
                lastError = "permanent HTTP \(response.statusCode)"
                _ = persistQueue()
                if current.id == targetID { targetResponse = response.withDeliveryState(.rejected) }
            } catch is CancellationError {
                if let index = queue.firstIndex(where: { $0.id == current.id }) {
                    scheduleRetry(at: index, policy: retryPolicy, response: nil)
                }
                return (.queued(), acceptedCount)
            } catch {
                lastError = String(describing: type(of: error)).prefix(160).description
                if let index = queue.firstIndex(where: { $0.id == current.id }) {
                    scheduleRetry(at: index, policy: retryPolicy, response: nil)
                }
                return (.queued(), acceptedCount)
            }
        }
        return (targetResponse ?? (targetID == nil ? .acceptedEmpty() : .queued()), acceptedCount)
    }

    private func scheduleRetry(at index: Int, policy: LogisterRetryPolicy, response: LogisterResponse?) {
        queue[index].attemptCount += 1
        let delay = min(max(policy.delay(after: queue[index].attemptCount, response: response), 1), 86_400)
        queue[index].nextAttemptAt = Date().addingTimeInterval(delay)
        lastError = response.map { "HTTP \($0.statusCode)" } ?? lastError ?? "delivery retry scheduled"
        _ = persistQueue()
    }

    private func pruneExpired(now: Date) {
        let cutoff = now.addingTimeInterval(-configuration.maximumQueueAge)
        let before = queue.count
        queue.removeAll { $0.capturedAt < cutoff }
        discardedEventCount += before - queue.count
    }

    private func enforceQueueBounds() {
        while queue.count > configuration.maximumQueuedEvents || queue.reduce(0, { $0 + $1.body.count }) > configuration.maximumQueueBytes {
            guard !queue.isEmpty else { break }
            let lowestPriority = queue.map(\.priority).min() ?? 0
            let evictionIndex = queue.firstIndex(where: { $0.priority == lowestPriority }) ?? queue.startIndex
            queue.remove(at: evictionIndex)
            discardedEventCount += 1
        }
    }

    @discardableResult
    private func persistQueue() -> Bool {
        do {
            try FileManager.default.createDirectory(at: queueURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if queue.isEmpty {
                if FileManager.default.fileExists(atPath: queueURL.path) { try FileManager.default.removeItem(at: queueURL) }
                return true
            }
            let data = try JSONEncoder().encode(PersistedQueue(schemaVersion: 1, entries: queue))
            try data.write(to: queueURL, options: [.atomic])
            Self.excludeFromBackup(queueURL)
            return true
        } catch {
            lastError = "queue persistence failed"
            return false
        }
    }

    private func persistInstallation() {
        guard let installation else { return }
        do {
            try FileManager.default.createDirectory(at: installationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(installation).write(to: installationURL, options: [.atomic])
            Self.excludeFromBackup(installationURL)
        } catch {
            lastError = "installation persistence failed"
        }
    }

    private static func defaultStorageDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("org.logister/Delivery", isDirectory: true)
    }

    private static func storageScope(endpoint: URL, service: String?, explicit: String?) -> String {
        sha256([
            endpoint.absoluteString,
            service ?? Bundle.main.bundleIdentifier ?? "",
            explicit ?? "",
            ProcessInfo.processInfo.processName
        ].joined(separator: "\u{0}"))
            .prefix(24)
            .description
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func loadQueue(from url: URL, configuration: LogisterConfiguration) -> [QueuedEnvelope] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        do {
            let persisted = try JSONDecoder().decode(PersistedQueue.self, from: data)
            let cutoff = Date().addingTimeInterval(-configuration.maximumQueueAge)
            return persisted.entries.filter { $0.capturedAt >= cutoff }
        } catch {
            let quarantine = url.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: quarantine)
            try? FileManager.default.moveItem(at: url, to: quarantine)
            return []
        }
    }

    private static func loadInstallation(from url: URL) -> PersistedInstallation? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PersistedInstallation.self, from: data)
    }

    private static func excludeFromBackup(_ url: URL) {
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutableURL.setResourceValues(values)
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }
}

extension LogisterResponse {
    static func queued() -> LogisterResponse {
        LogisterResponse(statusCode: 0, body: Data("queued for retry".utf8), deliveryState: .queued)
    }

    static func dropped(_ reason: String) -> LogisterResponse {
        LogisterResponse(statusCode: 0, body: Data("dropped: \(reason)".utf8), deliveryState: .dropped)
    }

    static func acceptedEmpty() -> LogisterResponse {
        LogisterResponse(statusCode: 204, deliveryState: .accepted)
    }
}
