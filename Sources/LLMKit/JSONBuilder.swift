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
