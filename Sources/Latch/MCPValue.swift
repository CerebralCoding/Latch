import Foundation

enum MCPValue: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([MCPValue]), object([String: MCPValue])

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() {
            self = .null
        } else if let flag = try? value.decode(Bool.self) {
            self = .bool(flag)
        } else if let number = try? value.decode(Double.self) {
            self = .number(number)
        } else if let text = try? value.decode(String.self) {
            self = .string(text)
        } else if let array = try? value.decode([MCPValue].self) {
            self = .array(array)
        } else {
            self = try .object(value.decode([String: MCPValue].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case let .bool(flag): try value.encode(flag)
        case let .number(number): try value.encode(number)
        case let .string(text): try value.encode(text)
        case let .array(array): try value.encode(array)
        case let .object(object): try value.encode(object)
        }
    }

    subscript(_ key: String) -> MCPValue? {
        if case let .object(object) = self {
            return object[key]
        }
        return nil
    }

    var string: String? {
        if case let .string(value) = self {
            return value
        }; return nil
    }

    var object: [String: MCPValue]? {
        if case let .object(value) = self {
            return value
        }; return nil
    }

    static func encoded(_ value: some Encodable) throws -> MCPValue {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try JSONDecoder().decode(Self.self, from: encoder.encode(value))
    }
}

extension MCPValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(stringLiteral value: String) {
        self = .string(value)
    }

    init(integerLiteral value: Int) {
        self = .number(Double(value))
    }

    init(booleanLiteral value: Bool) {
        self = .bool(value)
    }

    init(arrayLiteral elements: MCPValue...) {
        self = .array(elements)
    }

    init(dictionaryLiteral elements: (String, MCPValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}

struct MCPFailure: Error {
    let code: Int
    let message: String
    static func invalid(_ message: String) -> Self {
        Self(code: -32602, message: message)
    }
}

struct MCPArguments {
    let values: [String: MCPValue]

    init(_ value: MCPValue?, allowed: Set<String>) throws {
        guard let values = (value ?? [:]).object, Set(values.keys).isSubset(of: allowed) else {
            throw MCPFailure.invalid("arguments must be an object with only the documented properties")
        }
        self.values = values
    }

    func text(_ key: String, default fallback: String? = nil, maximum: Int = 4096) throws -> String {
        if values[key] == nil, let fallback {
            return fallback
        }
        guard let value = values[key]?.string, !value.isEmpty, value.utf8.count <= maximum, !value.utf8.contains(0) else {
            throw MCPFailure.invalid("\(key) requires a nonempty string of at most \(maximum) bytes without NUL")
        }
        return value
    }

    func number(_ key: String, default fallback: Double, range: ClosedRange<Double>, integer: Bool = false) throws -> Double {
        guard let value = values[key] else { return fallback }
        guard case let .number(number) = value, number.isFinite, range.contains(number), !integer || number.rounded() == number else {
            throw MCPFailure.invalid("\(key) requires \(integer ? "an integer" : "a number") in \(range)")
        }
        return number
    }

    func flag(_ key: String) throws -> Bool {
        guard let value = values[key] else { return false }
        guard case let .bool(flag) = value else { throw MCPFailure.invalid("\(key) requires a boolean") }
        return flag
    }
}
