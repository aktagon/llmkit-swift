import Foundation

/// The internal JSON waist shared by both directions (ADR-066 SWIFT-002).
///
/// A hand-rolled value type — deliberately NOT `Codable`, `JSONEncoder`, or
/// `[String: Any]`. `Codable` cannot express the dynamic dotted-path body
/// construction and root-merge the request pipeline needs; `[String: Any]`
/// collapses `Bool` into `NSNumber` (so `true` can serialize as `1`), a
/// wire-golden hazard. Keeping `.int(Int64)` and `.double` as distinct cases
/// and hand-writing the serializer removes that hazard and gives token-for-token
/// control over number representation.
public enum JSONValue: Sendable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    /// Object as ordered key/value pairs so insertion order is preserved for
    /// deterministic serialization. Equality is order-insensitive (see `==`).
    case object([(String, JSONValue)])
}

// MARK: - Equality (order-insensitive for objects)

extension JSONValue: Equatable {
    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case let (.string(a), .string(b)): return a == b
        case let (.int(a), .int(b)): return a == b
        case let (.double(a), .double(b)): return a == b
        case let (.bool(a), .bool(b)): return a == b
        case (.null, .null): return true
        case let (.array(a), .array(b)): return a == b
        case let (.object(a), .object(b)):
            guard a.count == b.count else { return false }
            // Group values per key (order preserved within a key) so equality
            // stays order-insensitive across distinct keys, but duplicate-key
            // value lists must match — deduping would call
            // [("k",1),("k",1)] equal to [("k",1),("k",2)] even though they
            // serialize differently.
            var da: [String: [JSONValue]] = [:]
            for (key, value) in a { da[key, default: []].append(value) }
            var db: [String: [JSONValue]] = [:]
            for (key, value) in b { db[key, default: []].append(value) }
            return da == db
        default:
            return false
        }
    }
}

// MARK: - Member / path access

extension JSONValue {
    /// The value for `key` when this is an object, else nil.
    func member(_ key: String) -> JSONValue? {
        if case let .object(pairs) = self {
            return pairs.first(where: { $0.0 == key })?.1
        }
        return nil
    }

    /// The element at `index` when this is an array in bounds, else nil.
    func element(at index: Int) -> JSONValue? {
        if case let .array(items) = self, index >= 0, index < items.count {
            return items[index]
        }
        return nil
    }

    /// Navigate a dotted path (with optional `field[index]` array segments,
    /// e.g. `choices[0].message.content`). Returns nil on any miss.
    func lookup(_ path: String) -> JSONValue? {
        if path.isEmpty { return nil }
        var current: JSONValue? = self
        for rawPart in path.split(separator: ".") {
            guard let node = current else { return nil }
            let part = String(rawPart)
            if let open = part.firstIndex(of: "["), let close = part.firstIndex(of: "]") {
                let field = String(part[part.startIndex..<open])
                let indexText = part[part.index(after: open)..<close]
                guard let index = Int(indexText) else { return nil }
                let container = field.isEmpty ? node : node.member(field)
                current = container?.element(at: index)
            } else {
                current = node.member(part)
            }
        }
        return current
    }

    /// String at a dotted path, coercing scalars; empty string on miss.
    func stringValue(at path: String) -> String {
        switch lookup(path) {
        case let .string(value): return value
        case let .int(value): return String(value)
        case let .double(value): return String(value)
        case let .bool(value): return String(value)
        default: return ""
        }
    }

    /// Integer at a dotted path; 0 on miss.
    func intValue(at path: String) -> Int {
        switch lookup(path) {
        case let .int(value): return Int(value)
        case let .double(value): return Int(value)
        default: return 0
        }
    }

    /// Double at a dotted path; 0.0 on miss.
    func doubleValue(at path: String) -> Double {
        switch lookup(path) {
        case let .double(value): return value
        case let .int(value): return Double(value)
        default: return 0.0
        }
    }
}

// MARK: - Serialization (deterministic, never exponent form)

extension JSONValue {
    /// Serialize to a compact JSON string. Object keys keep insertion order;
    /// numbers never use exponent notation (the load-bearing wire-golden risk,
    /// ADR-066 SWIFT-002).
    func serialized() -> String {
        switch self {
        case let .string(value):
            return JSONValue.encodeString(value)
        case let .int(value):
            return String(value)
        case let .double(value):
            return JSONValue.encodeDouble(value)
        case let .bool(value):
            return value ? "true" : "false"
        case .null:
            return "null"
        case let .array(items):
            return "[" + items.map { $0.serialized() }.joined(separator: ",") + "]"
        case let .object(pairs):
            let body = pairs
                .map { JSONValue.encodeString($0.0) + ":" + $0.1.serialized() }
                .joined(separator: ",")
            return "{" + body + "}"
        }
    }

    static func encodeString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }

    /// Render a double without exponent form. Integral values keep a trailing
    /// `.0` to stay a JSON number distinct from an integer literal.
    static func encodeDouble(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e16 {
            return String(format: "%.1f", value)
        }
        let text = String(value)
        // Swift's Double description does not use exponent form in the ranges
        // this SDK emits (temperature, penalties); guard anyway.
        return text.contains("e") || text.contains("E")
            ? String(format: "%f", value)
            : text
    }
}

// MARK: - Parsing (hand-rolled, int/double preserved)

extension JSONValue {
    enum ParseError: Error, Equatable {
        case unexpectedEnd
        case unexpected(Character, at: Int)
        case invalidNumber(String)
        case invalidEscape
    }

    /// Parse a JSON document into a `JSONValue`. Distinguishes integers from
    /// doubles by the number token (a `.`/`e`/`E` marks a double), so booleans
    /// and integers never collapse the way `JSONSerialization` + `NSNumber`
    /// would.
    static func parse(_ text: String) throws -> JSONValue {
        var parser = Parser(Array(text))
        let value = try parser.parseValue()
        parser.skipWhitespace()
        guard parser.index >= parser.scalars.count else {
            throw ParseError.unexpected(parser.scalars[parser.index], at: parser.index)
        }
        return value
    }

    private struct Parser {
        let scalars: [Character]
        var index: Int = 0

        init(_ scalars: [Character]) { self.scalars = scalars }

        mutating func skipWhitespace() {
            while index < scalars.count {
                let c = scalars[index]
                if c == " " || c == "\n" || c == "\r" || c == "\t" {
                    index += 1
                } else {
                    break
                }
            }
        }

        mutating func parseValue() throws -> JSONValue {
            skipWhitespace()
            guard index < scalars.count else { throw ParseError.unexpectedEnd }
            let c = scalars[index]
            switch c {
            case "{": return try parseObject()
            case "[": return try parseArray()
            case "\"": return .string(try parseString())
            case "t", "f": return try parseBool()
            case "n": return try parseNull()
            default: return try parseNumber()
            }
        }

        mutating func expect(_ ch: Character) throws {
            guard index < scalars.count else { throw ParseError.unexpectedEnd }
            guard scalars[index] == ch else { throw ParseError.unexpected(scalars[index], at: index) }
            index += 1
        }

        mutating func parseObject() throws -> JSONValue {
            try expect("{")
            var pairs: [(String, JSONValue)] = []
            skipWhitespace()
            if index < scalars.count, scalars[index] == "}" {
                index += 1
                return .object(pairs)
            }
            while true {
                skipWhitespace()
                let key = try parseString()
                skipWhitespace()
                try expect(":")
                let value = try parseValue()
                pairs.append((key, value))
                skipWhitespace()
                guard index < scalars.count else { throw ParseError.unexpectedEnd }
                if scalars[index] == "," {
                    index += 1
                    continue
                }
                try expect("}")
                break
            }
            return .object(pairs)
        }

        mutating func parseArray() throws -> JSONValue {
            try expect("[")
            var items: [JSONValue] = []
            skipWhitespace()
            if index < scalars.count, scalars[index] == "]" {
                index += 1
                return .array(items)
            }
            while true {
                let value = try parseValue()
                items.append(value)
                skipWhitespace()
                guard index < scalars.count else { throw ParseError.unexpectedEnd }
                if scalars[index] == "," {
                    index += 1
                    continue
                }
                try expect("]")
                break
            }
            return .array(items)
        }

        mutating func parseString() throws -> String {
            try expect("\"")
            var out = ""
            while index < scalars.count {
                let c = scalars[index]
                index += 1
                if c == "\"" {
                    return out
                }
                if c == "\\" {
                    guard index < scalars.count else { throw ParseError.unexpectedEnd }
                    let esc = scalars[index]
                    index += 1
                    switch esc {
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    case "/": out.append("/")
                    case "n": out.append("\n")
                    case "r": out.append("\r")
                    case "t": out.append("\t")
                    case "b": out.append("\u{08}")
                    case "f": out.append("\u{0C}")
                    case "u":
                        out.append(try parseUnicodeEscape())
                    default:
                        throw ParseError.invalidEscape
                    }
                } else {
                    out.append(c)
                }
            }
            throw ParseError.unexpectedEnd
        }

        mutating func parseUnicodeEscape() throws -> Character {
            let code = try parseHexCodeUnit()
            if (0xD800...0xDBFF).contains(code) {
                // High surrogate: legal only as the first half of a
                // \uXXXX\uXXXX pair (how JSON escapes non-BMP characters).
                // Require the literal low-surrogate escape and combine per
                // UTF-16.
                guard index + 2 <= scalars.count, scalars[index] == "\\", scalars[index + 1] == "u" else {
                    throw ParseError.invalidEscape
                }
                index += 2
                let low = try parseHexCodeUnit()
                guard (0xDC00...0xDFFF).contains(low) else { throw ParseError.invalidEscape }
                let combined = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                guard let scalar = Unicode.Scalar(combined) else { throw ParseError.invalidEscape }
                return Character(scalar)
            }
            // A lone low surrogate is not a valid scalar; Unicode.Scalar
            // rejects it here (matching strict JSON decoders).
            guard let scalar = Unicode.Scalar(code) else { throw ParseError.invalidEscape }
            return Character(scalar)
        }

        mutating func parseHexCodeUnit() throws -> UInt32 {
            guard index + 4 <= scalars.count else { throw ParseError.unexpectedEnd }
            let hex = String(scalars[index..<index + 4])
            guard let code = UInt32(hex, radix: 16) else { throw ParseError.invalidEscape }
            index += 4
            return code
        }

        mutating func parseBool() throws -> JSONValue {
            if matches("true") { return .bool(true) }
            if matches("false") { return .bool(false) }
            throw ParseError.unexpected(scalars[index], at: index)
        }

        mutating func parseNull() throws -> JSONValue {
            if matches("null") { return .null }
            throw ParseError.unexpected(scalars[index], at: index)
        }

        mutating func matches(_ literal: String) -> Bool {
            let chars = Array(literal)
            guard index + chars.count <= scalars.count else { return false }
            for (offset, ch) in chars.enumerated() where scalars[index + offset] != ch {
                return false
            }
            index += chars.count
            return true
        }

        mutating func parseNumber() throws -> JSONValue {
            let start = index
            var isDouble = false
            while index < scalars.count {
                let c = scalars[index]
                if c == "-" || c == "+" || (c >= "0" && c <= "9") {
                    index += 1
                } else if c == "." || c == "e" || c == "E" {
                    isDouble = true
                    index += 1
                } else {
                    break
                }
            }
            let token = String(scalars[start..<index])
            if isDouble {
                guard let value = Double(token) else { throw ParseError.invalidNumber(token) }
                return .double(value)
            }
            guard let value = Int64(token) else { throw ParseError.invalidNumber(token) }
            return .int(value)
        }
    }
}
