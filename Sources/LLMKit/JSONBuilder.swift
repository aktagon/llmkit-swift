import Foundation

///
///
///
///
///
///
///
///
enum JSONObject {
    ///
    static func set(_ obj: inout [(String, JSONValue)], _ key: String, _ value: JSONValue) {
        if let index = obj.firstIndex(where: { $0.0 == key }) {
            obj[index].1 = value
        } else {
            obj.append((key, value))
        }
    }

    ///
    static func remove(_ obj: inout [(String, JSONValue)], _ key: String) {
        obj.removeAll(where: { $0.0 == key })
    }

    ///
    static func value(_ obj: [(String, JSONValue)], _ key: String) -> JSONValue? {
        obj.first(where: { $0.0 == key })?.1
    }

    ///
    ///
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

    ///
    ///
    ///
    ///
    ///
    ///
    ///
    ///
    ///
    ///
    ///
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

    ///
    ///
    private static func splitIndex(_ part: String) -> (field: String, index: Int?) {
        guard let open = part.firstIndex(of: "["), let close = part.firstIndex(of: "]"),
              let index = Int(part[part.index(after: open)..<close]) else {
            return (part, nil)
        }
        return (String(part[part.startIndex..<open]), index)
    }

    ///
    private static func childObject(_ obj: [(String, JSONValue)], _ key: String) -> [(String, JSONValue)] {
        if case let .object(existing)? = value(obj, key) { return existing }
        return []
    }

    ///
    ///
    ///
    private static func isEmptyWireValue(_ candidate: JSONValue) -> Bool {
        switch candidate {
        case let .string(text): return text.isEmpty
        case let .int(number): return number == 0
        case let .double(number): return number == 0
        case .null: return true
        default: return false
        }
    }

    ///
    ///
    ///
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

    ///
    ///
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
