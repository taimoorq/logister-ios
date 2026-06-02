import Foundation

public struct LogisterEventOptions: Equatable, Sendable {
    public var level: String?
    public var fingerprint: String?
    public var occurredAt: Date?
    public var environment: String?
    public var release: String?
    public var traceID: String?
    public var requestID: String?
    public var sessionID: String?
    public var userID: String?
    public var transactionName: String?
    public var durationMs: Double?
    public var context: LogisterContext

    public init(
        level: String? = nil,
        fingerprint: String? = nil,
        occurredAt: Date? = nil,
        environment: String? = nil,
        release: String? = nil,
        traceID: String? = nil,
        requestID: String? = nil,
        sessionID: String? = nil,
        userID: String? = nil,
        transactionName: String? = nil,
        durationMs: Double? = nil,
        context: LogisterContext = [:]
    ) {
        self.level = level
        self.fingerprint = fingerprint
        self.occurredAt = occurredAt
        self.environment = environment
        self.release = release
        self.traceID = traceID
        self.requestID = requestID
        self.sessionID = sessionID
        self.userID = userID
        self.transactionName = transactionName
        self.durationMs = durationMs
        self.context = context
    }
}

public struct LogisterEvent: Equatable, Sendable {
    public var eventType: String
    public var message: String?
    public var level: String?
    public var fingerprint: String?
    public var occurredAt: Date?
    public var context: LogisterContext
    public var attributes: LogisterContext

    public init(
        eventType: String,
        message: String? = nil,
        level: String? = nil,
        fingerprint: String? = nil,
        occurredAt: Date? = nil,
        context: LogisterContext = [:],
        attributes: LogisterContext = [:]
    ) {
        self.eventType = eventType
        self.message = message
        self.level = level
        self.fingerprint = fingerprint
        self.occurredAt = occurredAt
        self.context = context
        self.attributes = attributes
    }
}

public struct LogisterSpan: Equatable, Sendable {
    public var traceID: String
    public var spanID: String
    public var parentSpanID: String?
    public var name: String
    public var kind: String
    public var status: String?
    public var durationMs: Double
    public var startedAt: Date?
    public var endedAt: Date?
    public var context: LogisterContext

    public init(
        traceID: String,
        spanID: String = UUID().uuidString,
        parentSpanID: String? = nil,
        name: String,
        kind: String = "internal",
        status: String? = nil,
        durationMs: Double,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        context: LogisterContext = [:]
    ) {
        self.traceID = traceID
        self.spanID = spanID
        self.parentSpanID = parentSpanID
        self.name = name
        self.kind = kind
        self.status = status
        self.durationMs = durationMs
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.context = context
    }

    var event: LogisterEvent {
        var attributes: LogisterContext = [
            "trace_id": .string(traceID),
            "span_id": .string(spanID),
            "name": .string(name),
            "kind": .string(kind),
            "duration_ms": .number(durationMs)
        ]

        if let parentSpanID {
            attributes["parent_span_id"] = .string(parentSpanID)
        }
        if let status {
            attributes["status"] = .string(status)
        }
        if let startedAt {
            attributes["started_at"] = .string(LogisterDates.string(from: startedAt))
        }
        if let endedAt {
            attributes["ended_at"] = .string(LogisterDates.string(from: endedAt))
        }

        return LogisterEvent(
            eventType: "span",
            message: name,
            context: context,
            attributes: attributes
        )
    }
}
