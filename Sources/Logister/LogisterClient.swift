import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct LogisterResponse: Equatable, Sendable {
    public var statusCode: Int
    public var body: Data
    public var headers: [String: String]

    public init(statusCode: Int, body: Data = Data(), headers: [String: String] = [:]) {
        self.statusCode = statusCode
        self.body = body
        self.headers = headers
    }

    public var accepted: Bool {
        (200..<300).contains(statusCode)
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
        if let retryAfter = response?.headers.first(where: { $0.key.caseInsensitiveCompare("Retry-After") == .orderedSame })?.value,
           let seconds = TimeInterval(retryAfter), seconds >= 0 {
            return min(seconds, maximumDelay)
        }
        return min(baseDelay * pow(2, Double(max(0, attempt - 1))), maximumDelay)
    }
}

public enum LogisterError: Error, Equatable {
    case invalidPayload
    case invalidResponse
    case invalidMobileIngestToken
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

    init(provider: any LogisterTokenProvider, refreshSkew: TimeInterval) {
        self.provider = provider
        self.refreshSkew = refreshSkew
    }

    func mobileIngestToken() async throws -> String {
        let now = Date()
        if let cachedToken, !cachedToken.shouldRefresh(now: now, refreshSkew: refreshSkew) {
            return cachedToken.token
        }

        let fresh = try await provider.fetchToken()
        guard !fresh.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LogisterError.invalidMobileIngestToken
        }
        guard !fresh.isExpired(now: Date()) else {
            throw LogisterError.invalidMobileIngestToken
        }

        cachedToken = fresh
        return fresh.token
    }
}

public struct LogisterClient: Sendable {
    public var endpoint: URL
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
            exceptionDataPolicy: .full,
            platformContextPolicy: .standard,
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
            exceptionDataPolicy: .full,
            platformContextPolicy: .standard,
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
        self.tokenStore = LogisterTokenStore(provider: tokenProvider, refreshSkew: tokenRefreshSkew)
    }

    @discardableResult
    public func capture(_ event: LogisterEvent, options: LogisterEventOptions = LogisterEventOptions()) async throws -> LogisterResponse {
        let envelope = ["event": try eventPayload(event, options: options)]
        guard JSONSerialization.isValidJSONObject(envelope) else {
            throw LogisterError.invalidPayload
        }

        let body = try JSONSerialization.data(withJSONObject: envelope, options: [])
        let mobileIngestToken = try await tokenStore.mobileIngestToken()
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
                    "triggered": .bool(true),
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
            "data_policy": .string(exceptionDataPolicy.rawValue)
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

    private func eventPayload(_ event: LogisterEvent, options: LogisterEventOptions) throws -> [String: Any] {
        var payload: [String: Any] = [
            "event_type": event.eventType
        ]

        put(event.eventID?.uuidString.lowercased(), into: &payload, key: "uuid")
        put(event.message, into: &payload, key: "message")
        put(options.level ?? event.level, into: &payload, key: "level")
        put(options.fingerprint ?? event.fingerprint, into: &payload, key: "fingerprint")
        put(options.occurredAt.map(LogisterDates.string) ?? event.occurredAt.map(LogisterDates.string), into: &payload, key: "occurred_at")
        put(options.environment ?? environment, into: &payload, key: "environment")
        put(options.release ?? release ?? LogisterPlatformContext.inferredRelease, into: &payload, key: "release")
        put(options.traceID, into: &payload, key: "trace_id")
        put(options.requestID, into: &payload, key: "request_id")
        put(options.sessionID, into: &payload, key: "session_id")
        put(options.userID, into: &payload, key: "user_id")
        put(options.transactionName, into: &payload, key: "transaction_name")
        put(options.durationMs, into: &payload, key: "duration_ms")

        for (key, value) in event.attributes {
            payload[key] = value.jsonObject
        }

        var context = baseContext()
        context = merge(context, with: event.context)
        context = merge(context, with: options.context)
        putIfMissing(options.environment ?? environment, into: &context, key: "environment")
        putIfMissing(options.release ?? release ?? LogisterPlatformContext.inferredRelease, into: &context, key: "release")
        putIfMissing(options.traceID, into: &context, key: "trace_id")
        putIfMissing(options.requestID, into: &context, key: "request_id")
        putIfMissing(options.sessionID, into: &context, key: "session_id")
        putIfMissing(options.userID, into: &context, key: "user_id")
        putIfMissing(options.transactionName, into: &context, key: "transaction_name")
        putIfMissing(options.durationMs, into: &context, key: "duration_ms")
        if let sessionID = options.sessionID {
            mergeObject(["id": .string(sessionID)], into: &context, key: "session")
        }
        if let installationIDHash = options.installationIDHash {
            mergeObject(["id_hash": .string(installationIDHash)], into: &context, key: "installation")
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
        payload["context"] = context.mapValues { $0.jsonObject }

        return payload
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

    private func put<T>(_ value: T?, into payload: inout [String: Any], key: String) {
        if let value {
            payload[key] = value
        }
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
