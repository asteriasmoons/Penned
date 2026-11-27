import Foundation

nonisolated public enum RailwayJSON: Codable, Equatable, Sendable {
    case null, bool(Bool), integer(Int64), number(Double), string(String), array([Self]), object([String:Self])
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int64.self) { self = .integer(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([Self].self) { self = .array(v) }
        else { self = .object(try c.decode([String:Self].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
    public subscript(_ key: String) -> Self? { if case .object(let v) = self { return v[key] }; return nil }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var object: [String:Self]? { if case .object(let v) = self { return v }; return nil }
    public var integer: Int64? { if case .integer(let v) = self { return v }; return nil }
    public static var encoder: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return e }
    public static func from<T: Encodable>(_ value:T) throws -> Self { try JSONDecoder().decode(Self.self, from:encoder.encode(value)) }
    public func decode<T: Decodable>(_ type:T.Type) throws -> T { try JSONDecoder().decode(type,from:Self.encoder.encode(self)) }
    public static func timestamp(_ date: Date = Date()) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime,.withFractionalSeconds]; return f.string(from:date)
    }
    public static func date(_ value:String) throws -> Date {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        if let d = f.date(from:value) { return d }
        f.formatOptions = [.withInternetDateTime]
        guard let d = f.date(from:value) else { throw RailwayError.invalidResponse }; return d
    }
}

nonisolated public enum RailwayError: LocalizedError, Equatable, Sendable {
    case invalidConfiguration, invalidParameter, invalidResponse, accountMismatch, signedOut, releaseDisabled
    case http(Int,String?,String?), corruptFile, unsupportedRecord, staleCheckpoint, migrationNotVerified, migrationConfirmationRequired
    public var errorDescription:String? {
        switch self {
        case .signedOut,.accountMismatch: "Penned account authentication is required."
        case .corruptFile: "A required file could not be verified. Your local changes are retained."
        case .migrationNotVerified,.migrationConfirmationRequired,.staleCheckpoint,.releaseDisabled:
            "Your cloud library is not ready for this operation."
        case .http: "Penned Cloud Sync is temporarily unavailable."
        default: "Penned Cloud Sync could not complete this operation."
        }
    }
    public var retryable: Bool {
        if case .http(let status,let code,_) = self { return status == 408 || status == 429 || status >= 500 || code == "sync_dependency_pending" }
        return false
    }
}

nonisolated public struct RailwayEnvelope<Value: Codable & Sendable>: Codable, Sendable {
    public let data: Value
    public let pagination: RailwayJSON?
    public let operation: RailwayJSON?
}

nonisolated public struct RailwayCursor: Comparable, Sendable {
    public let value: Int64
    public init(_ text:String) throws {
        guard let n = Int64(text), n >= 0, String(n) == text else { throw RailwayError.invalidResponse }
        value = n
    }
    public static func <(lhs:Self,rhs:Self)->Bool { lhs.value < rhs.value }
}
