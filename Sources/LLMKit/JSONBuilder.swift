import Foundation

/// Mutation helpers that treat a `[(String, JSONValue)]` as a mutable JSON
/// object during request construction. The request pipeline builds the body on
/// ordered key/value pairs (so serialization is deterministic, ADR-066
/// SWIFT-002); these re-express the four operations Rust's `request.rs`
/// performs on `serde_json::Map` — nested insert, parent merge, deep merge,
/// remove — over ordered pairs. All are recursive and create intermediate
/// objects on demand, mirroring `insert_nested_field` / `merge_into_parent` /
/// `deep_merge` byte-for-byte in effect (value-equal, not key-order-equal).
enum JSONObject {
    /// Set `key` (replace an existing pair, else append) — object insert.
    static func set(_ obj: inout [(String, JSONValue)], _ key: String, _ value: JSONValue) {
        if let index = obj.firstIndex(where: { $0.0 == key }) {
            obj[index].1 = value
        } else {
            obj.append((key, value))
        }
    }

    /// Remove a top-level `key`.
    static func remove(_ obj: inout [(String, JSONValue)], _ key: String) {
        obj.removeAll(where: { $0.0 == key })
    }

    /// The value for a top-level `key`, or nil.
    static func value(_ obj: [(String, JSONValue)], _ key: String) -> JSONValue? {
        obj.first(where: { $0.0 == key })?.1
    }

    /// Insert `value` at a dotted `path`, creating (or replacing non-object)
    /// intermediate objects — mirror of `insert_nested_field`.
    static func insertNested(_ obj: inout [(String, JSONValue)], _ path: String, _ value: JSONValue) {
        insertParts(&obj, path.split(separator: ".").map(String.init), value)
    }

    private static func insertParts(
        _ obj: inout [(String, JSONValue)],
        _ parts: [String],
        _ value: JSONValue
    ) {
        guard let head = parts.first else { return }
        if parts.count == 1 {
            set(&obj, head, value)
            return
        }
        var child: [(String, JSONValue)] = []
        if let index = obj.firstIndex(where: { $0.0 == head }),
           case let .object(existing) = obj[index].1 {
            child = existing
        }
        insertParts(&child, Array(parts.dropFirst()), value)
        set(&obj, head, .object(child))
    }

    /// Place `newValue` at a dotted `path` with array index support
    /// (`choices[0].message.content`), creating intermediate objects and array
    /// elements as it descends. It is the navigate-or-create inverse of
    /// `JSONValue.lookup` and walks the identical generated path strings
    /// (ADR-076 SYM-005). Unlike `insertNested`, ANY segment may be indexed —
    /// Google's response text path is `candidates[0].content.parts[0].text`, two
    /// array levels created in one descent.
    ///
    /// An empty path (the provider declares no location for this field) or an
    /// empty value is a no-op: there is nothing to write, and materializing a
    /// zero would invent a field the provider never sent.
    static func setWirePath(_ obj: inout [(String, JSONValue)], _ path: String, _ newValue: JSONValue) {
        if path.isEmpty || isEmptyWireValue(newValue) { return }
        setWireParts(&obj, path.split(separator: ".").map(String.init), newValue)
    }

    private static func setWireParts(
        _ obj: inout [(String, JSONValue)],
        _ parts: [String],
        _ newValue: JSONValue
    ) {
        guard let head = parts.first else { return }
        let rest = Array(parts.dropFirst())
        let (field, index) = splitIndex(head)

        guard let index else {
            if rest.isEmpty {
                set(&obj, field, newValue)
                return
            }
            var child = childObject(obj, field)
            setWireParts(&child, rest, newValue)
            set(&obj, field, .object(child))
            return
        }

        var items: [JSONValue] = []
        if case let .array(existing)? = value(obj, field) { items = existing }
        while items.count <= index { items.append(.null) }
        if rest.isEmpty {
            items[index] = newValue
        } else {
            var child: [(String, JSONValue)] = []
            if case let .object(existing) = items[index] { child = existing }
            setWireParts(&child, rest, newValue)
            items[index] = .object(child)
        }
        set(&obj, field, .array(items))
    }

    /// Split a `field[index]` segment into its parts; the index is nil for a
    /// plain object key.
    private static func splitIndex(_ part: String) -> (field: String, index: Int?) {
        guard let open = part.firstIndex(of: "["), let close = part.firstIndex(of: "]"),
              let index = Int(part[part.index(after: open)..<close]) else {
            return (part, nil)
        }
        return (String(part[part.startIndex..<open]), index)
    }

    /// The object at `key`, or a fresh one when absent or mistyped.
    private static func childObject(_ obj: [(String, JSONValue)], _ key: String) -> [(String, JSONValue)] {
        if case let .object(existing)? = value(obj, key) { return existing }
        return []
    }

    /// Whether `candidate` is the zero of its canonical type. Empty values are
    /// skipped rather than written, so the encoder never claims a provider
    /// reported zero tokens when the canonical `Response` simply had none.
    private static func isEmptyWireValue(_ candidate: JSONValue) -> Bool {
        switch candidate {
        case let .string(text): return text.isEmpty
        case let .int(number): return number == 0
        case let .double(number): return number == 0
        case .null: return true
        default: return false
        }
    }

    /// Merge `extras` into the object that CONTAINS the leaf of `path`: for
    /// "a.b.c" they land in obj["a"]["b"]; for a top-level path, in obj.
    /// Mirror of `merge_into_parent`.
    static func mergeIntoParent(
        _ obj: inout [(String, JSONValue)],
        _ path: String,
        _ extras: [(String, JSONValue)]
    ) {
        var parts = path.split(separator: ".").map(String.init)
        if !parts.isEmpty { parts.removeLast() } // drop the leaf
        mergeParent(&obj, parts, extras)
    }

    private static func mergeParent(
        _ obj: inout [(String, JSONValue)],
        _ parts: [String],
        _ extras: [(String, JSONValue)]
    ) {
        guard let head = parts.first else {
            for (key, value) in extras { set(&obj, key, value) }
            return
        }
        guard let index = obj.firstIndex(where: { $0.0 == head }),
              case var .object(child) = obj[index].1 else { return }
        mergeParent(&child, Array(parts.dropFirst()), extras)
        obj[index].1 = .object(child)
    }

    /// Deep-merge `src` into `dst`: when both hold an object at the same key the
    /// objects merge, else `src` overwrites. Mirror of `deep_merge`.
    static func deepMerge(_ dst: inout [(String, JSONValue)], _ src: [(String, JSONValue)]) {
        for (key, value) in src {
            if case let .object(sourceChild) = value,
               let index = dst.firstIndex(where: { $0.0 == key }),
               case var .object(destChild) = dst[index].1 {
                deepMerge(&destChild, sourceChild)
                dst[index].1 = .object(destChild)
            } else {
                set(&dst, key, value)
            }
        }
    }
}
