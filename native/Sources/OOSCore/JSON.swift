import Foundation

extension JSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral, ExpressibleByNilLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(nilLiteral: ()) { self = .null }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSON)...) { self = .object(Dictionary(uniqueKeysWithValues: elements)) }
    public func or(_ fallback: JSON) -> JSON { self == .null ? fallback : self }
    public var trimmed: String { string.trimmingCharacters(in: .whitespacesAndNewlines) }
    public func encoded(pretty: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public enum JSON: Sendable, Codable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([JSON]), object([String: JSON])
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
    public var string: String { if case .string(let v) = self { return v }; return "" }
    public var number: Double { if case .number(let v) = self { return v }; return 0 }
    public var bool: Bool { if case .bool(let v) = self { return v }; return false }
    public var array: [JSON] { if case .array(let v) = self { return v }; return [] }
    public var object: [String: JSON] { if case .object(let v) = self { return v }; return [:] }
    public subscript(_ key: String) -> JSON {
        get { object[key] ?? .null }
        set { var o = object; o[key] = newValue; self = .object(o) }
    }
    public var records: [Record] { array.map { Record($0.object) } }
    public static func text(_ value: String) -> JSON { value.isEmpty ? .null : .string(value) }
}

public struct Record: Sendable, Identifiable, Equatable, Codable {
    public var fields: [String: JSON]
    public init(_ fields: [String: JSON] = [:]) { self.fields = fields }
    public init(from decoder: Decoder) throws { fields = try [String: JSON](from: decoder) }
    public func encode(to encoder: Encoder) throws { try fields.encode(to: encoder) }
    public var id: String { self["id"].string }
    public subscript(_ key: String) -> JSON {
        get { fields[key] ?? .null }
        set { fields[key] = newValue }
    }
    public func text(_ key: String) -> String { self[key].string }
    public func number(_ key: String, _ fallback: Double = 0) -> Double {
        if case .number(let n) = self[key] { return n }; return fallback
    }
    public var title: String { text("title") }
    public var status: String { text("status") }
    public var isClosed: Bool { ["completed", "cancelled"].contains(status) }
    public var isArchived: Bool { self["archived"].bool }
    public var isOpen: Bool { !isArchived && !["completed", "cancelled", "paused"].contains(status) }
    public var isExecutionTracked: Bool { isOpen && status != "information" }
    public var json: JSON { .object(fields) }
}
