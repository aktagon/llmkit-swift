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
    /// The parser never produces a duplicate key (the last value wins, at the
    /// first key's position, as in every other SDK's codec); a hand-built
    /// duplicate reads through `member` as its last value.
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
    /// The value for `key` when this is an object, else nil. Last wins on a
    /// duplicate key, matching Go, JavaScript, Python, serde_json and Gson
    /// (BUG-065).
    func member(_ key: String) -> JSONValue? {
        if case let .object(pairs) = self {
            return pairs.last(where: { $0.0 == key })?.1
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

    /// Elements of the array at `blocksPath` that the marker identifies, in
    /// wire order. The single primitive behind every "which blocks in this
    /// response are of kind X" question — text extraction and tool-call
    /// extraction both run through it, so the two cannot come to disagree
    /// about what an array element is.
    ///
    /// Marker semantics are exactly the generated config contract:
    ///
    /// - `markerPath` empty: homogeneous array; every element matches
    /// - `markerPath` set, `markerValue` empty: matches if the key is PRESENT
    /// - both set: matches if the key EQUALS the value
    ///
    /// Presence rather than equality is not a shortcut: a Bedrock ContentBlock
    /// and a Gemini Part are UNIONS whose text member carries no type key at
    /// all, so an equality test there would match nothing.
    ///
    /// Navigation reuses `lookup`, so there is no second path grammar here.
    func matchingBlocks(
        _ blocksPath: String,
        _ markerPath: String,
        _ markerValue: String
    ) -> [JSONValue] {
        guard case let .array(items)? = lookup(blocksPath) else { return [] }

        var out: [JSONValue] = []
        for item in items {
            guard case .object = item else { continue }
            if !markerPath.isEmpty {
                guard let marker = item.member(markerPath) else { continue }
                if !markerValue.isEmpty {
                    guard case let .string(text) = marker, text == markerValue else { continue }
                }
            }
            out.append(item)
        }
        return out
    }

    /// String at a dotted path, coercing scalars; empty string on miss.
    public func stringValue(at path: String) -> String {
        switch lookup(path) {
        case let .string(value): return value
        case let .int(value): return String(value)
        case let .double(value): return String(value)
        case let .bool(value): return String(value)
        default: return ""
        }
    }

    /// Integer at a dotted path; 0 on miss. A number that is not exactly an
    /// `Int` (fractional, out of range, infinite) is a miss too: `Int(Double)`
    /// traps on those, and a trap is a process abort, never an error
    /// (BUG-065).
    public func intValue(at path: String) -> Int {
        return optInt(at: path) ?? 0
    }

    /// Double at a dotted path; 0.0 on miss.
    public func doubleValue(at path: String) -> Double {
        switch lookup(path) {
        case let .double(value): return value
        case let .int(value): return Double(value)
        default: return 0.0
        }
    }

    /// Integer at a dotted path, or `nil` when the provider declares no path
    /// for this field or the response did not carry it (ADR-081). The
    /// distinction `intValue(at:)` cannot draw: a provider reporting
    /// `cached_tokens: 0` and a provider that never mentions caching are
    /// different claims, and neither of them is the number zero.
    public func optInt(at path: String) -> Int? {
        guard !path.isEmpty else { return nil }
        switch lookup(path) {
        case let .int(value): return Int(exactly: value)
        case let .double(value): return Int(exactly: value)
        default: return nil
        }
    }

    /// Integer at a dotted path for a measured quantity such as a duration,
    /// truncated toward zero the way Go's `int(d)` is; `nil` on a miss, or
    /// when the number is not finite or does not fit. Counts use `optInt`,
    /// which refuses a fractional value (decision 2026-09-04, BUG-065).
    public func optTruncatedInt(at path: String) -> Int? {
        guard !path.isEmpty else { return nil }
        switch lookup(path) {
        case let .int(value): return Int(exactly: value)
        case let .double(value):
            guard value.isFinite else { return nil }
            return Int(exactly: value.rounded(.towardZero))
        default: return nil
        }
    }

    /// `optInt(at:)` for the fractional provider-reported USD cost (ADR-027).
    /// An unreported cost is not a free request (AVAIL-007).
    public func optDouble(at path: String) -> Double? {
        guard !path.isEmpty else { return nil }
        switch lookup(path) {
        case let .double(value): return value
        case let .int(value): return Double(value)
        default: return nil
        }
    }

    /// String at a dotted path as an optional canonical signal: an empty
    /// extraction means the provider declared no path or sent no value, which
    /// is absence, not the empty string.
    public func optString(at path: String) -> String? {
        let value = stringValue(at: path)
        return value.isEmpty ? nil : value
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
        // `String(Double)` gives the SHORTEST representation that round-trips,
        // but uses exponent form for small magnitudes. The old fallback was
        // `%f` — fixed at six decimal places, which silently truncated: a
        // provider-reported cost of 4.2e-06 rendered as 0.000004, losing the
        // 2 and disagreeing with the six SDKs that print it in full. Costs are
        // routinely this small, and no fixture exercised one until ADR-081
        // slice 4.1a captured a real OpenRouter cost.
        //
        // Expanding the exponent by hand keeps the shortest round-tripping
        // digits AND drops the exponent, instead of trading one for the other.
        guard text.contains("e") || text.contains("E") else { return text }
        return expandExponent(text)
    }

    /// Rewrite `"4.2e-06"` as `"0.0000042"` by shifting the decimal point.
    /// Digit-exact: it moves the point, it does not re-round.
    private static func expandExponent(_ text: String) -> String {
        let parts = text.lowercased().split(separator: "e")
        guard parts.count == 2, let exponent = Int(parts[1]) else { return text }
        let negative = parts[0].hasPrefix("-")
        let mantissa = parts[0].drop(while: { $0 == "-" || $0 == "+" })

        var digits = Array(mantissa.filter { $0 != "." })
        // Where the point sits in `digits` before the shift.
        let dot = mantissa.firstIndex(of: ".")
            .map { mantissa.distance(from: mantissa.startIndex, to: $0) } ?? digits.count
        var point = dot + exponent

        while point <= 0 { digits.insert("0", at: 0); point += 1 }
        while point > digits.count { digits.append("0") }

        let whole = String(digits[0..<point])
        let fraction = String(digits[point...])
        let body = fraction.isEmpty ? whole + ".0" : whole + "." + fraction
        return negative ? "-" + body : body
    }
}

// MARK: - Parsing (hand-rolled, int/double preserved)

extension JSONValue {
    enum ParseError: Error, Equatable {
        case unexpectedEnd
        case unexpected(Character, at: Int)
        case invalidNumber(String)
        case invalidEscape
        /// Arrays and objects nested deeper than `maxNestingDepth`. The
        /// parser recurses once per level, so an unbounded document is a
        /// stack overflow, which no `catch` can reach (BUG-065).
        case nestingTooDeep(Int)
    }

    /// Deepest array/object nesting the parser accepts. serde_json's default
    /// recursion limit, so Swift refuses the same documents Rust does.
    public static let maxNestingDepth = 128

    /// Parse a JSON document into a `JSONValue`. Distinguishes integers from
    /// doubles by the number token (a `.`/`e`/`E` marks a double), so booleans
    /// and integers never collapse the way `JSONSerialization` + `NSNumber`
    /// would.
    public static func parse(_ text: String) throws -> JSONValue {
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
        var depth: Int = 0

        init(_ scalars: [Character]) { self.scalars = scalars }

        mutating func enterContainer() throws {
            depth += 1
            guard depth <= JSONValue.maxNestingDepth else {
                throw ParseError.nestingTooDeep(JSONValue.maxNestingDepth)
            }
        }

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
            try enterContainer()
            defer { depth -= 1 }
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
                // Last wins, at the first key's position (BUG-065).
                if let existing = pairs.firstIndex(where: { $0.0 == key }) {
                    pairs[existing].1 = value
                } else {
                    pairs.append((key, value))
                }
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
            try enterContainer()
            defer { depth -= 1 }
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
