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
        // Equal jitter keeps half the backoff and spreads the rest, so clients
        // that failed together do not retry together.
        let backoff = min(baseDelay * pow(2, Double(max(0, attempt - 1))), maximumDelay)
        guard backoff > 0 else { return 0 }
        return backoff / 2 + Double.random(in: 0...(backoff / 2))
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

/// Sends envelopes on a dedicated ephemeral session with bounded timeouts. It
/// stores no cookies or cache and never follows a redirect, so the bearer
/// token is only ever sent to the configured endpoint.
public struct URLSessionLogisterTransport: LogisterTransport {
    static let requestTimeout: TimeInterval = 15
    static let resourceTimeout: TimeInterval = 60

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: LogisterRedirectRefusal(), delegateQueue: nil)
    }()

    public init() {
    }

    public func send(request: URLRequest, body: Data) async throws -> LogisterResponse {
        var request = request
        request.httpBody = body
        request.timeoutInterval = Self.requestTimeout
        let (data, response) = try await Self.session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LogisterError.invalidResponse
        }
        let headers = httpResponse.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            result[String(describing: entry.key)] = String(describing: entry.value)
        }
        return LogisterResponse(statusCode: httpResponse.statusCode, body: data, headers: headers)
    }
}

final class LogisterRedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
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

struct LogisterTokenProviderTimeout: Error {}

actor LogisterTokenStore {
    private let provider: any LogisterTokenProvider
    private let refreshSkew: TimeInterval
    private let timeout: TimeInterval
    private var cachedToken: LogisterToken?
    private var refreshTask: Task<LogisterToken, Error>?

    init(provider: any LogisterTokenProvider, refreshSkew: TimeInterval, timeout: TimeInterval) {
        self.provider = provider
        self.refreshSkew = refreshSkew
        self.timeout = timeout
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
            let provider = provider
            let timeout = timeout
            task = Task { try await Self.fetch(from: provider, timeout: timeout) }
            refreshTask = task
        }
        let fresh: LogisterToken
        do {
            fresh = try await task.value
        } catch {
            if refreshTask == task { refreshTask = nil }
            throw error
        }
        if refreshTask == task { refreshTask = nil }
        guard !fresh.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LogisterError.invalidMobileIngestToken
        }
        guard !fresh.isExpired(now: Date()) else {
            throw LogisterError.invalidMobileIngestToken
        }

        cachedToken = fresh
        return fresh.token
    }

    /// Forgets the cached token. A refresh already in flight is shared by
    /// other callers, so it is left to finish rather than cancelled.
    func invalidate() {
        cachedToken = nil
    }

    /// Returns the provider's token, or throws once `timeout` passes even if
    /// the provider ignores cancellation.
    private static func fetch(from provider: any LogisterTokenProvider, timeout: TimeInterval) async throws -> LogisterToken {
        try await withCheckedThrowingContinuation { continuation in
            let race = TokenFetchRace(continuation)
            let timer = Task {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                race.finish(.failure(LogisterTokenProviderTimeout()))
            }
            race.start(Task {
                do {
                    race.finish(.success(try await provider.fetchToken()))
                } catch {
                    race.finish(.failure(error))
                }
                timer.cancel()
            })
        }
    }
}

private final class TokenFetchRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<LogisterToken, Error>?
    private var work: Task<Void, Never>?

    init(_ continuation: CheckedContinuation<LogisterToken, Error>) {
        self.continuation = continuation
    }

    func start(_ work: Task<Void, Never>) {
        lock.lock()
        let finished = continuation == nil
        if !finished { self.work = work }
        lock.unlock()
        if finished { work.cancel() }
    }

    func finish(_ result: Result<LogisterToken, Error>) {
        lock.lock()
        let continuation = continuation
        let work = work
        self.continuation = nil
        self.work = nil
        lock.unlock()
        guard let continuation else { return }
        continuation.resume(with: result)
        if case .failure(let error) = result, error is LogisterTokenProviderTimeout { work?.cancel() }
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
    private let endpointPermitted: Bool

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
            exceptionDataPolicy: .typeAndStacktrace,
            platformContextPolicy: .standard,
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
            exceptionDataPolicy: .typeAndStacktrace,
            platformContextPolicy: .standard,
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

    /// Uses the `typeAndStacktrace` exception policy and the standard platform policy.
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
            exceptionDataPolicy: .typeAndStacktrace,
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

    /// Uses the `typeAndStacktrace` exception policy and the standard platform policy.
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
            exceptionDataPolicy: .typeAndStacktrace,
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
        self.tokenStore = LogisterTokenStore(
            provider: tokenProvider,
            refreshSkew: tokenRefreshSkew,
            timeout: min(max(configuration.tokenProviderTimeout, 1), 120)
        )
        self.endpointPermitted = Self.permitsEndpoint(endpoint, allowInsecure: configuration.allowsInsecureTransport)
        self.runtime = LogisterRuntime(endpoint: endpoint, service: service, configuration: configuration)
    }

    @discardableResult
    public func capture(_ event: LogisterEvent, options: LogisterEventOptions = LogisterEventOptions()) async throws -> LogisterResponse {
        guard endpointPermitted else {
            await runtime.recordDiscard(reason: "endpoint must use https")
            return .dropped("endpoint must use https")
        }
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
        } catch {
            await runtime.recordDiscard(reason: "invalid payload")
            return .dropped("invalid payload")
        }
        let envelope = ["event": payloadContext.mapValues(\.jsonObject)]
        guard JSONSerialization.isValidJSONObject(envelope),
              let body = try? JSONSerialization.data(withJSONObject: envelope, options: []) else {
            await runtime.recordDiscard(reason: "invalid payload")
            return .dropped("invalid payload")
        }

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
        guard endpointPermitted else { return 0 }
        return await runtime.flush(
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

    /// Telemetry carries a bearer token, so plain http is accepted only for
    /// loopback hosts or when `allowsInsecureTransport` is set.
    static func permitsEndpoint(_ endpoint: URL, allowInsecure: Bool) -> Bool {
        switch endpoint.scheme?.lowercased() {
        case "https":
            return true
        case "http":
            guard !allowInsecure else { return true }
            let host = (endpoint.host ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            return host == "localhost" || host.hasSuffix(".localhost") || host == "::1" || host.hasPrefix("127.")
        default:
            return false
        }
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
            exception["message"] = .string(error.localizedDescription)
            exception["domain"] = .string(bridgedError.domain)
            exception["code"] = .number(Double(bridgedError.code))
            let userInfo = Self.reviewedUserInfo(bridgedError)
            if !userInfo.isEmpty { exception["user_info"] = .object(userInfo) }
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
                    ? error.localizedDescription
                    : String(reflecting: Swift.type(of: error)),
                level: options.level ?? "error"
            ),
            options: eventOptions
        )
    }

    /// The `.full` policy sends only these `userInfo` entries. Arbitrary keys,
    /// file paths and debug descriptions often hold customer data.
    private static func reviewedUserInfo(_ error: NSError, depth: Int = 0) -> LogisterContext {
        var result: LogisterContext = [:]
        func put(_ value: Any?, as key: String) {
            let string: String?
            switch value {
            case let url as URL: string = url.absoluteString
            case let text as String: string = text
            default: string = nil
            }
            if let string, !string.isEmpty { result[key] = .string(String(string.prefix(512))) }
        }
        put(error.userInfo[NSLocalizedFailureReasonErrorKey], as: "failure_reason")
        put(error.userInfo[NSLocalizedRecoverySuggestionErrorKey], as: "recovery_suggestion")
        put(error.userInfo[NSURLErrorFailingURLErrorKey] ?? error.userInfo[NSURLErrorFailingURLStringErrorKey], as: "failing_url")
        if depth < 3, let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            var cause: LogisterContext = [
                "domain": .string(underlying.domain),
                "code": .number(Double(underlying.code))
            ]
            let nested = reviewedUserInfo(underlying, depth: depth + 1)
            if case .object(let next)? = nested["underlying"] { cause["underlying"] = .object(next) }
            result["underlying"] = .object(cause)
        }
        return result
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

        var processed = LogisterPrivacySanitizer.sanitizePayload(payload, policy: configuration.payloadPolicy)
        if let beforeSend = configuration.beforeSend {
            guard let candidate = beforeSend(processed) else { throw CaptureDiscard.beforeSend }
            processed = candidate
        }
        processed["uuid"] = payload["uuid"]
        processed["occurred_at"] = payload["occurred_at"]
        processed["evidence"] = payload["evidence"]
        for key in ["event_type", "message"] where !Self.isNonEmptyString(processed[key]) {
            processed[key] = payload[key]
        }
        guard Self.isNonEmptyString(processed["event_type"]), Self.isNonEmptyString(processed["message"]) else {
            throw LogisterError.invalidPayload
        }
        return try fittedPayload(processed)
    }

    /// Shrinks the context until the event fits the byte budget. Required
    /// envelope fields survive every step.
    private func fittedPayload(_ processed: LogisterContext) throws -> LogisterContext {
        let policy = configuration.payloadPolicy
        // The queued body wraps the event as {"event": ...}.
        let limit = policy.maximumEnvelopeBytes - 16
        var scale = 1
        while scale <= 64 {
            let candidate = LogisterPrivacySanitizer.sanitizePayload(processed, policy: policy, scale: scale)
            if let size = LogisterPrivacySanitizer.serializedSize(candidate.mapValues(\.jsonObject)), size <= limit {
                return candidate
            }
            scale *= 2
        }
        throw LogisterError.invalidPayload
    }

    private static func isNonEmptyString(_ value: LogisterValue?) -> Bool {
        guard case .string(let string) = value else { return false }
        return !string.isEmpty
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
