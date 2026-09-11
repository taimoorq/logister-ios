import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct LogisterResponse: Equatable, Sendable {
    public var statusCode: Int
    public var body: Data
    public var headers: [String: String]
    public var deliveryState: LogisterDeliveryState

    public init(statusCode: Int, body: Data = Data(), headers: [String: String] = [:]) {
        self.init(statusCode: statusCode, body: body, headers: headers, deliveryState: nil)
    }

    public init(
        statusCode: Int,
        body: Data = Data(),
        headers: [String: String] = [:],
        deliveryState: LogisterDeliveryState?
    ) {
        self.statusCode = statusCode
        self.body = body
        self.headers = headers
        self.deliveryState = deliveryState ?? ((200..<300).contains(statusCode) ? .accepted : .rejected)
    }

    public var accepted: Bool {
        deliveryState == .accepted && (200..<300).contains(statusCode)
    }

    func withDeliveryState(_ deliveryState: LogisterDeliveryState) -> LogisterResponse {
        var response = self
        response.deliveryState = deliveryState
        return response
    }
}

public struct LogisterRetryPolicy: Equatable, Sendable {
    public var maximumAttempts: Int
    public var baseDelay: TimeInterval
    public var maximumDelay: TimeInterval

    public init(maximumAttempts: Int = 3, baseDelay: TimeInterval = 0.25, maximumDelay: TimeInterval = 30) {
        self.maximumAttempts = max(1, maximumAttempts)
        self.baseDelay = max(0, baseDelay)
        self.maximumDelay = max(0, maximumDelay)
    }

    public static let `default` = LogisterRetryPolicy()
    public static let disabled = LogisterRetryPolicy(maximumAttempts: 1, baseDelay: 0, maximumDelay: 0)

    func shouldRetry(statusCode: Int) -> Bool {
        statusCode == 408 || statusCode == 425 || statusCode == 429 || (500...599).contains(statusCode)
    }

    func delay(after attempt: Int, response: LogisterResponse? = nil) -> TimeInterval {
        if let retryAfter = response?.headers.first(where: { $0.key.caseInsensitiveCompare("Retry-After") == .orderedSame })?.value {
            if let seconds = TimeInterval(retryAfter), seconds >= 0 {
                return min(seconds, maximumDelay)
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let date = formatter.date(from: retryAfter) {
                return min(max(0, date.timeIntervalSinceNow), maximumDelay)
            }
        }
        return min(baseDelay * pow(2, Double(max(0, attempt - 1))), maximumDelay)
    }
}

public enum LogisterError: Error, Equatable {
    case invalidPayload
    case invalidResponse
    case invalidMobileIngestToken
}

private enum CaptureDiscard: Error {
    case beforeSend
}

public protocol LogisterTransport: Sendable {
    func send(request: URLRequest, body: Data) async throws -> LogisterResponse
}

public struct URLSessionLogisterTransport: LogisterTransport {
    public init() {
    }

    public func send(request: URLRequest, body: Data) async throws -> LogisterResponse {
        var request = request
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LogisterError.invalidResponse
        }
        let headers = httpResponse.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            result[String(describing: entry.key)] = String(describing: entry.value)
        }
        return LogisterResponse(statusCode: httpResponse.statusCode, body: data, headers: headers)
    }
}

public struct LogisterToken: Equatable, Sendable {
    public var token: String
    public var expiresAt: Date

    public init(token: String, expiresAt: Date) {
        self.token = token
        self.expiresAt = expiresAt
    }

    fileprivate func isExpired(now: Date) -> Bool {
        expiresAt <= now
    }

    fileprivate func shouldRefresh(now: Date, refreshSkew: TimeInterval) -> Bool {
        expiresAt <= now.addingTimeInterval(refreshSkew)
    }
}

public protocol LogisterTokenProvider: Sendable {
    func fetchToken() async throws -> LogisterToken
}

private actor LogisterTokenStore {
    private let provider: any LogisterTokenProvider
    private let refreshSkew: TimeInterval
    private var cachedToken: LogisterToken?
    private var refreshTask: Task<LogisterToken, Error>?

    init(provider: any LogisterTokenProvider, refreshSkew: TimeInterval) {
        self.provider = provider
        self.refreshSkew = refreshSkew
    }

    func mobileIngestToken() async throws -> String {
        let now = Date()
        if let cachedToken, !cachedToken.shouldRefresh(now: now, refreshSkew: refreshSkew) {
            return cachedToken.token
        }

        let task: Task<LogisterToken, Error>
        if let refreshTask {
            task = refreshTask
        } else {
            task = Task { try await provider.fetchToken() }
            refreshTask = task
        }
        let fresh: LogisterToken
        do {
            fresh = try await task.value
        } catch {
            refreshTask = nil
            throw error
        }
        refreshTask = nil
        guard !fresh.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LogisterError.invalidMobileIngestToken
        }
        guard !fresh.isExpired(now: Date()) else {
            throw LogisterError.invalidMobileIngestToken
        }

        cachedToken = fresh
        return fresh.token
    }

    func invalidate() {
        cachedToken = nil
        refreshTask?.cancel()
        refreshTask = nil
    }
}

public struct LogisterClient: Sendable {
    public let endpoint: URL
    public var environment: String?
    public var release: String?
    public var repository: String?
    public var commitSHA: String?
    public var branch: String?
    public var service: String?
    public var defaultContext: LogisterContext

    private let transport: LogisterTransport
    private let tokenStore: LogisterTokenStore
    private let retryPolicy: LogisterRetryPolicy
    private let exceptionDataPolicy: LogisterExceptionDataPolicy
    private let platformContextPolicy: LogisterPlatformContextPolicy
    private let configuration: LogisterConfiguration
    private let runtime: LogisterRuntime

    // Retain the initializer symbols exposed by the last public Swift package.
    public init(
        baseURL: URL,
        tokenProvider: any LogisterTokenProvider,
        environment: String? = nil,
        release: String? = nil,
        repository: String? = nil,
        commitSHA: String? = nil,
        branch: String? = nil,
        service: String? = nil,
        defaultContext: LogisterContext = [:],
        tokenRefreshSkew: TimeInterval = 60,
        retryPolicy: LogisterRetryPolicy = .default,
        transport: LogisterTransport = URLSessionLogisterTransport()
    ) {
        self.init(
            baseURL: baseURL,
            tokenProvider: tokenProvider,
            environment: environment,
            release: release,
            repository: repository,
            commitSHA: commitSHA,
            branch: branch,
            service: service,
            defaultContext: defaultContext,
            tokenRefreshSkew: tokenRefreshSkew,
            retryPolicy: retryPolicy,
            configuration: .default,
            transport: transport
        )
    }

    public init(
        baseURL: URL,
        tokenProvider: any LogisterTokenProvider,
        environment: String? = nil,
        release: String? = nil,
        repository: String? = nil,
        commitSHA: String? = nil,
        branch: String? = nil,
        service: String? = nil,
        defaultContext: LogisterContext = [:],
        tokenRefreshSkew: TimeInterval = 60,
        retryPolicy: LogisterRetryPolicy = .default,
        exceptionDataPolicy: LogisterExceptionDataPolicy,
        platformContextPolicy: LogisterPlatformContextPolicy = .standard,
        transport: LogisterTransport = URLSessionLogisterTransport()
    ) {
        self.init(
            baseURL: baseURL,
            tokenProvider: tokenProvider,
            environment: environment,
            release: release,
            repository: repository,
            commitSHA: commitSHA,
            branch: branch,
            service: service,
            defaultContext: defaultContext,
            tokenRefreshSkew: tokenRefreshSkew,
            retryPolicy: retryPolicy,
            exceptionDataPolicy: exceptionDataPolicy,
            platformContextPolicy: platformContextPolicy,
            configuration: .default,
            transport: transport
        )
    }

    public init(
        endpoint: URL,
        tokenProvider: any LogisterTokenProvider,
        environment: String? = nil,
        release: String? = nil,
        repository: String? = nil,
        commitSHA: String? = nil,
        branch: String? = nil,
        service: String? = nil,
        defaultContext: LogisterContext = [:],
        tokenRefreshSkew: TimeInterval = 60,
        retryPolicy: LogisterRetryPolicy = .default,
        transport: LogisterTransport = URLSessionLogisterTransport()
    ) {
        self.init(
            endpoint: endpoint,
            tokenProvider: tokenProvider,
            environment: environment,
            release: release,
            repository: repository,
            commitSHA: commitSHA,
            branch: branch,
            service: service,
            defaultContext: defaultContext,
            tokenRefreshSkew: tokenRefreshSkew,
            retryPolicy: retryPolicy,
            configuration: .default,
            transport: transport
        )
    }

    public init(
        endpoint: URL,
        tokenProvider: any LogisterTokenProvider,
        environment: String? = nil,
        release: String? = nil,
        repository: String? = nil,
        commitSHA: String? = nil,
        branch: String? = nil,
        service: String? = nil,
        defaultContext: LogisterContext = [:],
        tokenRefreshSkew: TimeInterval = 60,
        retryPolicy: LogisterRetryPolicy = .default,
        exceptionDataPolicy: LogisterExceptionDataPolicy,
        platformContextPolicy: LogisterPlatformContextPolicy = .standard,
        transport: LogisterTransport = URLSessionLogisterTransport()
    ) {
        self.init(
            endpoint: endpoint,
            tokenProvider: tokenProvider,
            environment: environment,
            release: release,
            repository: repository,
            commitSHA: commitSHA,
            branch: branch,
            service: service,
            defaultContext: defaultContext,
            tokenRefreshSkew: tokenRefreshSkew,
            retryPolicy: retryPolicy,
            exceptionDataPolicy: exceptionDataPolicy,
            platformContextPolicy: platformContextPolicy,
            configuration: .default,
            transport: transport
        )
    }

    @available(*, deprecated, message: "Choose an explicit exceptionDataPolicy and platformContextPolicy.")
    public init(
        baseURL: URL,
        tokenProvider: any LogisterTokenProvider,
        environment: String? = nil,
        release: String? = nil,
        repository: String? = nil,
        commitSHA: String? = nil,
        branch: String? = nil,
        service: String? = nil,
        defaultContext: LogisterContext = [:],
        tokenRefreshSkew: TimeInterval = 60,
        retryPolicy: LogisterRetryPolicy = .default,
        configuration: LogisterConfiguration,
        transport: LogisterTransport = URLSessionLogisterTransport()
    ) {
        self.init(
            baseURL: baseURL,
            tokenProvider: tokenProvider,
            environment: environment,
            release: release,
            repository: repository,
            commitSHA: commitSHA,
            branch: branch,
            service: service,
            defaultContext: defaultContext,
            tokenRefreshSkew: tokenRefreshSkew,
            retryPolicy: retryPolicy,
            exceptionDataPolicy: .full,
            platformContextPolicy: .standard,
            configuration: configuration,
            transport: transport
        )
    }

    public init(
        baseURL: URL,
        tokenProvider: any LogisterTokenProvider,
        environment: String? = nil,
        release: String? = nil,
        repository: String? = nil,
        commitSHA: String? = nil,
        branch: String? = nil,
        service: String? = nil,
        defaultContext: LogisterContext = [:],
        tokenRefreshSkew: TimeInterval = 60,
        retryPolicy: LogisterRetryPolicy = .default,
        exceptionDataPolicy: LogisterExceptionDataPolicy,
        platformContextPolicy: LogisterPlatformContextPolicy = .standard,
        configuration: LogisterConfiguration,
        transport: LogisterTransport = URLSessionLogisterTransport()
    ) {
        self.init(
            endpoint: baseURL.appendingPathComponent("api/v1/ingest_events"),
            tokenProvider: tokenProvider,
            environment: environment,
            release: release,
            repository: repository,
            commitSHA: commitSHA,
            branch: branch,
            service: service,
            defaultContext: defaultContext,
            tokenRefreshSkew: tokenRefreshSkew,
            retryPolicy: retryPolicy,
            exceptionDataPolicy: exceptionDataPolicy,
            platformContextPolicy: platformContextPolicy,
            configuration: configuration,
            transport: transport
        )
    }

    @available(*, deprecated, message: "Choose an explicit exceptionDataPolicy and platformContextPolicy.")
    public init(
        endpoint: URL,
        tokenProvider: any LogisterTokenProvider,
        environment: String? = nil,
        release: String? = nil,
        repository: String? = nil,
        commitSHA: String? = nil,
        branch: String? = nil,
        service: String? = nil,
        defaultContext: LogisterContext = [:],
        tokenRefreshSkew: TimeInterval = 60,
        retryPolicy: LogisterRetryPolicy = .default,
        configuration: LogisterConfiguration,
        transport: LogisterTransport = URLSessionLogisterTransport()
    ) {
        self.init(
            endpoint: endpoint,
            tokenProvider: tokenProvider,
            environment: environment,
            release: release,
            repository: repository,
            commitSHA: commitSHA,
            branch: branch,
            service: service,
            defaultContext: defaultContext,
            tokenRefreshSkew: tokenRefreshSkew,
            retryPolicy: retryPolicy,
            exceptionDataPolicy: .full,
            platformContextPolicy: .standard,
            configuration: configuration,
            transport: transport
        )
    }

    public init(
        endpoint: URL,
        tokenProvider: any LogisterTokenProvider,
        environment: String? = nil,
        release: String? = nil,
        repository: String? = nil,
        commitSHA: String? = nil,
        branch: String? = nil,
        service: String? = nil,
        defaultContext: LogisterContext = [:],
        tokenRefreshSkew: TimeInterval = 60,
        retryPolicy: LogisterRetryPolicy = .default,
        exceptionDataPolicy: LogisterExceptionDataPolicy,
        platformContextPolicy: LogisterPlatformContextPolicy = .standard,
        configuration: LogisterConfiguration,
        transport: LogisterTransport = URLSessionLogisterTransport()
    ) {
        self.endpoint = endpoint
        self.environment = environment
        self.release = release
        self.repository = repository
        self.commitSHA = commitSHA
        self.branch = branch
        self.service = service
        self.defaultContext = defaultContext
        self.transport = transport
        self.retryPolicy = retryPolicy
        self.exceptionDataPolicy = exceptionDataPolicy
        self.platformContextPolicy = platformContextPolicy
        self.configuration = configuration
        self.tokenStore = LogisterTokenStore(provider: tokenProvider, refreshSkew: tokenRefreshSkew)
        self.runtime = LogisterRuntime(endpoint: endpoint, service: service, configuration: configuration)
    }

    @discardableResult
    public func capture(_ event: LogisterEvent, options: LogisterEventOptions = LogisterEventOptions()) async throws -> LogisterResponse {
        let eventID = event.eventID ?? UUID()
        let capturedAt = options.occurredAt ?? event.occurredAt ?? Date()
        let captureState = await runtime.captureState(now: capturedAt, category: collectionCategory(for: event))
        guard captureState.collectionEnabled else { return .dropped("collection disabled") }
        let payloadContext: LogisterContext
        do {
            payloadContext = try eventPayload(
                event,
                options: options,
                eventID: eventID,
            capturedAt: capturedAt,
            installationIDHash: captureState.installationIDHash,
            identityEnabled: captureState.identityEnabled
            )
        } catch CaptureDiscard.beforeSend {
            await runtime.recordDiscard(reason: "beforeSend discarded event")
            return .dropped("beforeSend discarded event")
        }
        let envelope = ["event": payloadContext.mapValues(\.jsonObject)]
        guard JSONSerialization.isValidJSONObject(envelope) else {
            throw LogisterError.invalidPayload
        }

        let body = try JSONSerialization.data(withJSONObject: envelope, options: [])
        return await runtime.enqueueAndDrain(
            id: eventID,
            capturedAt: capturedAt,
            body: body,
            priority: deliveryPriority(for: event),
            retryPolicy: retryPolicy,
            sender: { body in try await send(body: body) }
        )
    }

    public func flushQueuedEvents() async -> Int {
        await runtime.flush(
            retryPolicy: retryPolicy,
            force: true,
            sender: { body in try await send(body: body) }
        )
    }

    public func setCollectionEnabled(_ enabled: Bool, purgeOnDisable: Bool = true) async {
        await runtime.setCollectionEnabled(enabled, purgeOnDisable: purgeOnDisable)
    }

    public func healthSnapshot() async -> LogisterClientHealth {
        await runtime.health()
    }

    func setMetricKitSubscribed(_ subscribed: Bool) async {
        await runtime.setMetricKitSubscribed(subscribed)
    }

    private func send(body: Data) async throws -> LogisterResponse {
        var mobileIngestToken = try await tokenStore.mobileIngestToken()
        var response = try await send(body: body, mobileIngestToken: mobileIngestToken)
        if response.statusCode == 401 {
            await tokenStore.invalidate()
            mobileIngestToken = try await tokenStore.mobileIngestToken()
            response = try await send(body: body, mobileIngestToken: mobileIngestToken)
        }
        return response
    }

    private func send(body: Data, mobileIngestToken: String) async throws -> LogisterResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(mobileIngestToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("\(LogisterSDK.name)/\(LogisterSDK.version)", forHTTPHeaderField: "User-Agent")

        return try await sendWithRetry(request: request, body: body)
    }

    @discardableResult
    public func captureException(_ error: Error, options: LogisterEventOptions = LogisterEventOptions()) async throws -> LogisterResponse {
        var context = options.context
        let stacktrace = LogisterStackFrameParser.frames(
            from: Thread.callStackSymbols,
            applicationImage: Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        )
        var exception: LogisterContext = [
            "type": .string(String(reflecting: Swift.type(of: error))),
            "stacktrace": .array(stacktrace),
            "threads": .array([
                .object([
                    "id": .string("reporting-thread"),
                    "name": .string("Reporting thread"),
                    "triggered": .bool(false),
                    "role": .string("reporting"),
                    "frames": .array(stacktrace)
                ])
            ])
        ]
        if exceptionDataPolicy == .full {
            let bridgedError = error as NSError
            exception["message"] = .string(String(describing: error))
            exception["domain"] = .string(bridgedError.domain)
            exception["code"] = .number(Double(bridgedError.code))
        }
        context["exception"] = .object(exception)
        context["diagnostic"] = .object([
            "source": .string("sdk"),
            "kind": .string("reported_error")
        ])
        context["error"] = .object([
            "mechanism": .string("handled_exception"),
            "handled": .bool(true),
            "fatal": .bool(false),
            "capture_source": .string("manual"),
            "data_policy": .string(exceptionDataPolicy.rawValue),
            "thread_role": .string("reporting")
        ])
        context["symbolication"] = .object([
            "status": .string("not_required")
        ])

        var eventOptions = options
        eventOptions.context = context

        return try await capture(
            LogisterEvent(
                eventType: "error",
                message: exceptionDataPolicy == .full
                    ? String(describing: error)
                    : String(reflecting: Swift.type(of: error)),
                level: options.level ?? "error"
            ),
            options: eventOptions
        )
    }

    @discardableResult
    public func captureMessage(_ message: String, options: LogisterEventOptions = LogisterEventOptions()) async throws -> LogisterResponse {
        try await capture(
            LogisterEvent(eventType: "log", message: message, level: options.level ?? "info"),
            options: options
        )
    }

    @discardableResult
    public func captureMetric(_ name: String, value: Double, unit: String? = nil, options: LogisterEventOptions = LogisterEventOptions()) async throws -> LogisterResponse {
        var context = options.context
        context["value"] = .number(value)
        if let unit {
            context["unit"] = .string(unit)
        }

        var eventOptions = options
        eventOptions.context = context
        return try await capture(LogisterEvent(eventType: "metric", message: name), options: eventOptions)
    }

    @discardableResult
    public func captureTransaction(_ name: String, durationMs: Double, options: LogisterEventOptions = LogisterEventOptions()) async throws -> LogisterResponse {
        var attributes: LogisterContext = [
            "transaction_name": .string(name),
            "duration_ms": .number(durationMs)
        ]
        if let duration = options.durationMs {
            attributes["duration_ms"] = .number(duration)
        }

        return try await capture(
            LogisterEvent(eventType: "transaction", message: name, attributes: attributes),
            options: options
        )
    }

    @discardableResult
    public func captureSpan(_ span: LogisterSpan, options: LogisterEventOptions = LogisterEventOptions()) async throws -> LogisterResponse {
        try await capture(span.event, options: options)
    }

    @discardableResult
    public func checkIn(_ slug: String, status: String, options: LogisterEventOptions = LogisterEventOptions()) async throws -> LogisterResponse {
        var context = options.context
        context["check_in_slug"] = .string(slug)
        context["check_in_status"] = .string(status)

        var eventOptions = options
        eventOptions.context = context
        return try await capture(LogisterEvent(eventType: "check_in", message: slug), options: eventOptions)
    }

    private func eventPayload(
        _ event: LogisterEvent,
        options: LogisterEventOptions,
        eventID: UUID,
        capturedAt: Date,
        installationIDHash: String?,
        identityEnabled: Bool
    ) throws -> LogisterContext {
        let sourceDiagnostic = objectValue(event.context["diagnostic"])
        let source = stringValue(sourceDiagnostic["source"]) ?? "sdk"
        let delayedSource = source == "metrickit"
        var payload = event.attributes
        payload["event_type"] = .string(event.eventType)
        payload["message"] = .string(event.message ?? event.eventType)
        put(options.level ?? event.level, into: &payload, key: "level")
        put(options.fingerprint ?? event.fingerprint, into: &payload, key: "fingerprint")
        put(
            delayedSource ? stringValue(event.context["environment"]) : options.environment ?? environment,
            into: &payload,
            key: "environment"
        )
        put(
            delayedSource ? stringValue(event.context["release"]) : options.release ?? release ?? LogisterPlatformContext.inferredRelease,
            into: &payload,
            key: "release"
        )
        put(options.traceID, into: &payload, key: "trace_id")
        put(options.requestID, into: &payload, key: "request_id")
        put(identityEnabled ? options.sessionID : nil, into: &payload, key: "session_id")
        put(identityEnabled ? options.userID : nil, into: &payload, key: "user_id")
        put(options.transactionName, into: &payload, key: "transaction_name")
        put(options.durationMs, into: &payload, key: "duration_ms")

        var context = delayedSource ? sourceBaseContext() : baseContext()
        context = merge(context, with: event.context)
        context = merge(context, with: options.context)
        if !delayedSource {
            putIfMissing(options.environment ?? environment, into: &context, key: "environment")
            putIfMissing(options.release ?? release ?? LogisterPlatformContext.inferredRelease, into: &context, key: "release")
        }
        putIfMissing(options.traceID, into: &context, key: "trace_id")
        putIfMissing(options.requestID, into: &context, key: "request_id")
        putIfMissing(identityEnabled ? options.sessionID : nil, into: &context, key: "session_id")
        putIfMissing(identityEnabled ? options.userID : nil, into: &context, key: "user_id")
        putIfMissing(options.transactionName, into: &context, key: "transaction_name")
        putIfMissing(options.durationMs, into: &context, key: "duration_ms")
        if identityEnabled, let sessionID = options.sessionID {
            var session: LogisterContext = ["id": .string(sessionID)]
            if let sessionStartedAt = options.sessionStartedAt {
                session["started_at"] = .string(LogisterDates.string(from: sessionStartedAt))
            }
            mergeObject(session, into: &context, key: "session")
        }
        if identityEnabled, let installationIDHash = options.installationIDHash ?? installationIDHash {
            mergeObject(
                [
                    "id_hash": .string(installationIDHash),
                    "scope": .string("delivery_installation")
                ],
                into: &context,
                key: "installation"
            )
        }
        if let distributionChannel = options.distributionChannel {
            mergeObject(["channel": .string(distributionChannel)], into: &context, key: "distribution")
        }
        if let inForeground = options.inForeground {
            mergeObject(["in_foreground": .bool(inForeground)], into: &context, key: "app")
        }
        if !options.breadcrumbs.isEmpty {
            context["breadcrumbs"] = .array(options.breadcrumbs.map(\.value))
        }
        context["platform"] = .string("ios")
        context = LogisterPrivacySanitizer.sanitize(context)
        let evidence = evidence(for: event, context: context)
        payload["uuid"] = .string(eventID.uuidString.lowercased())
        if !delayedSource, evidence["reporting_period"] == nil {
            payload["occurred_at"] = .string(LogisterDates.string(from: capturedAt))
        } else {
            payload.removeValue(forKey: "occurred_at")
        }
        payload["evidence"] = .object(evidence)
        payload["context"] = .object(context)

        guard var processed = LogisterPrivacySanitizer.sanitizePayload(
            payload,
            policy: configuration.payloadPolicy
        ) else {
            throw LogisterError.invalidPayload
        }
        if let beforeSend = configuration.beforeSend {
            guard let candidate = beforeSend(processed) else { throw CaptureDiscard.beforeSend }
            processed = candidate
        }
        processed["uuid"] = payload["uuid"]
        processed["occurred_at"] = payload["occurred_at"]
        processed["evidence"] = payload["evidence"]
        guard case .string(let eventType) = processed["event_type"], !eventType.isEmpty,
              case .string(let message) = processed["message"], !message.isEmpty,
              let final = LogisterPrivacySanitizer.sanitizePayload(
                processed,
                policy: configuration.payloadPolicy
              ) else {
            throw LogisterError.invalidPayload
        }
        let byteCount = try JSONSerialization.data(
            withJSONObject: final.mapValues(\.jsonObject),
            options: []
        ).count
        guard byteCount <= configuration.payloadPolicy.maximumEnvelopeBytes else {
            throw LogisterError.invalidPayload
        }

        return final
    }

    private func evidence(for event: LogisterEvent, context: LogisterContext) -> LogisterContext {
        let diagnostic = objectValue(context["diagnostic"])
        let error = objectValue(context["error"])
        let source = stringValue(diagnostic["source"]) ?? "sdk"
        let kind = stringValue(diagnostic["kind"]) ?? event.eventType
        let captureSource = stringValue(error["capture_source"])

        var evidence: LogisterContext = [
            "source": .string(source),
            "kind": .string(kind),
            "capture_mode": .string(source == "metrickit" ? "metrickit_payload" : captureSource ?? "manual_capture"),
            "evidence_kind": .string(source == "metrickit" ? "event_payload" : event.eventType == "error" ? "reported_stack" : "event_payload"),
            "identity_scope": .string("occurrence"),
            "producer": .object([
                "sdk_name": .string(LogisterSDK.name),
                "sdk_version": .string(LogisterSDK.version)
            ])
        ]
        if case .object(let reportingPeriod) = diagnostic["reporting_period"] {
            evidence["reporting_period"] = .object(reportingPeriod)
        }
        return evidence
    }

    private func objectValue(_ value: LogisterValue?) -> LogisterContext {
        guard case .object(let object) = value else { return [:] }
        return object
    }

    private func stringValue(_ value: LogisterValue?) -> String? {
        guard case .string(let string) = value else { return nil }
        return string
    }

    private func sendWithRetry(request: URLRequest, body: Data) async throws -> LogisterResponse {
        var attempt = 1
        while true {
            do {
                let response = try await transport.send(request: request, body: body)
                guard attempt < retryPolicy.maximumAttempts, retryPolicy.shouldRetry(statusCode: response.statusCode) else {
                    return response
                }
                try await waitBeforeRetry(attempt: attempt, response: response)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard attempt < retryPolicy.maximumAttempts else { throw error }
                try await waitBeforeRetry(attempt: attempt)
            }
            attempt += 1
        }
    }

    private func waitBeforeRetry(attempt: Int, response: LogisterResponse? = nil) async throws {
        let delay = retryPolicy.delay(after: attempt, response: response)
        guard delay > 0 else { return }
        let boundedDelay = min(delay, 86_400)
        try await Task.sleep(nanoseconds: UInt64(boundedDelay * 1_000_000_000))
    }

    private func baseContext() -> LogisterContext {
        var context = LogisterPlatformContext.context(service: service, policy: platformContextPolicy)
        if let service {
            context["service"] = .string(service)
        }
        if let repository {
            context["repository"] = .string(repository)
        }
        if let commitSHA {
            context["commit_sha"] = .string(commitSHA)
        }
        if let branch {
            context["branch"] = .string(branch)
        }
        context = merge(context, with: defaultContext)
        return context
    }

    private func sourceBaseContext() -> LogisterContext {
        [
            "telemetry_schema_version": .number(Double(LogisterSDK.telemetrySchemaVersion)),
            "platform": .string("ios"),
            "apple_platform": .string(LogisterPlatformContext.applePlatform),
            "sdk": .object([
                "name": .string(LogisterSDK.name),
                "version": .string(LogisterSDK.version),
                "source_context": .string("diagnostic_payload")
            ])
        ]
    }

    private func collectionCategory(for event: LogisterEvent) -> LogisterCollectionCategory {
        let diagnostic = objectValue(event.context["diagnostic"])
        if stringValue(diagnostic["source"]) == "metrickit" { return .metricKit }
        switch event.eventType {
        case "error": return .errors
        case "metric": return .metrics
        case "transaction", "span": return .performance
        case "check_in": return .checkIns
        default: return .logs
        }
    }

    private func deliveryPriority(for event: LogisterEvent) -> Int {
        let category = collectionCategory(for: event)
        switch category {
        case .errors, .metricKit: return 3
        case .checkIns: return 2
        default: return 1
        }
    }

    private func merge(_ original: LogisterContext, with overrides: LogisterContext) -> LogisterContext {
        var result = original
        for (key, value) in overrides {
            if case .object(let existing) = result[key], case .object(let replacement) = value {
                result[key] = .object(merge(existing, with: replacement))
            } else {
                result[key] = value
            }
        }
        return result
    }

    private func mergeObject(_ object: LogisterContext, into context: inout LogisterContext, key: String) {
        let existing: LogisterContext
        if case .object(let value) = context[key] {
            existing = value
        } else {
            existing = [:]
        }
        context[key] = .object(merge(existing, with: object))
    }

    private func put(_ value: String?, into payload: inout LogisterContext, key: String) {
        if let value { payload[key] = .string(value) }
    }

    private func put(_ value: Double?, into payload: inout LogisterContext, key: String) {
        if let value { payload[key] = .number(value) }
    }

    private func putIfMissing(_ value: String?, into context: inout LogisterContext, key: String) {
        guard let value, context[key] == nil else {
            return
        }
        context[key] = .string(value)
    }

    private func putIfMissing(_ value: Double?, into context: inout LogisterContext, key: String) {
        guard let value, context[key] == nil else {
            return
        }
        context[key] = .number(value)
    }
}

enum LogisterDates {
    static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
