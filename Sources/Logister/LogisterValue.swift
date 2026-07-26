import Foundation

public typealias LogisterContext = [String: LogisterValue]

public enum LogisterValue: Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object(LogisterContext)
    case array([LogisterValue])
    case null

    public init(_ value: String) {
        self = .string(value)
    }

    public init(_ value: Int) {
        self = .number(Double(value))
    }

    public init(_ value: Double) {
        self = .number(value)
    }

    public init(_ value: Bool) {
        self = .bool(value)
    }

    init?(jsonObject: Any) {
        switch jsonObject {
        case let value as String:
            self = .string(value)
        case let value as Bool:
            self = .bool(value)
        case let value as NSNumber:
            self = .number(value.doubleValue)
        case let value as [String: Any]:
            self = .object(value.reduce(into: LogisterContext()) { result, entry in
                if let converted = LogisterValue(jsonObject: entry.value) {
                    result[entry.key] = converted
                }
            })
        case let value as [Any]:
            self = .array(value.compactMap(LogisterValue.init(jsonObject:)))
        case is NSNull:
            self = .null
        default:
            return nil
        }
    }

    var jsonObject: Any {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return value
        case .bool(let value):
            return value
        case .object(let value):
            return value.mapValues { $0.jsonObject }
        case .array(let value):
            return value.map { $0.jsonObject }
        case .null:
            return NSNull()
        }
    }
}
