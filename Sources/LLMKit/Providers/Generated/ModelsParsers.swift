//


import Foundation

///
///
///
///

///
struct ParsedModelRecord: Sendable, Equatable {
    var id: String = ""
    var displayName: String = ""
    var description: String = ""
    var created: Int = 0
    var contextWindow: Int = 0
    var maxOutput: Int = 0
    var raw: JSONValue?
}

///
///
struct ParsedModelsPage: Sendable, Equatable {
    var records: [ParsedModelRecord] = []
    var nextCursor: String = ""
}

///
///
struct ModelsParseError: Error, Equatable {
    let provider: String
    let reason: String
}

///
///
///
private func parseISO8601Best(_ s: String) -> Int {
    if s.isEmpty { return 0 }
    let plain = ISO8601DateFormatter()
    if let date = plain.date(from: s) {
        return Int(date.timeIntervalSince1970)
    }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: s) {
        return Int(date.timeIntervalSince1970)
    }
    return 0
}

///
func parseAnthropicModelsResponse(_ body: Data) throws -> ParsedModelsPage {
    let envelope: JSONValue
    do {
        envelope = try JSONValue.parse(String(decoding: body, as: UTF8.self))
    } catch {
        throw ModelsParseError(provider: "anthropic", reason: "envelope: \(error)")
    }
    var records: [ParsedModelRecord] = []
    if case let .array(data)? = envelope.member("data") {
        for wire in data {
            let maxOut: Int
            let declared = wire.intValue(at: "max_output_tokens")
            if declared > 0 {
                maxOut = declared
            } else {
                maxOut = wire.intValue(at: "max_tokens")
            }
            records.append(ParsedModelRecord(
                id: wire.stringValue(at: "id"),
                displayName: wire.stringValue(at: "display_name"),
                description: "",
                created: parseISO8601Best(wire.stringValue(at: "created_at")),
                contextWindow: wire.intValue(at: "max_input_tokens"),
                maxOutput: maxOut,
                raw: wire
            ))
        }
    }
    var nextCursor = ""
    if case let .bool(hasMore)? = envelope.member("has_more"), hasMore {
        nextCursor = envelope.stringValue(at: "last_id")
    }
    return ParsedModelsPage(records: records, nextCursor: nextCursor)
}

///
///
///
///
func parseOpenAICohortModelsResponse(_ body: Data) throws -> ParsedModelsPage {
    let parsed: JSONValue
    do {
        parsed = try JSONValue.parse(String(decoding: body, as: UTF8.self))
    } catch {
        throw ModelsParseError(provider: "openai-cohort", reason: "envelope: \(error)")
    }
    let data: [JSONValue]
    if case let .array(arr) = parsed {
        data = arr
    } else if case let .array(arr)? = parsed.member("data") {
        data = arr
    } else {
        data = []
    }
    let records = data.map { wire in
        ParsedModelRecord(
            id: wire.stringValue(at: "id"),
            displayName: "",
            description: "",
            created: wire.intValue(at: "created"),
            contextWindow: 0,
            maxOutput: 0,
            raw: wire
        )
    }
    return ParsedModelsPage(records: records, nextCursor: "")
}

///
///
func parseGoogleModelsResponse(_ body: Data) throws -> ParsedModelsPage {
    let envelope: JSONValue
    do {
        envelope = try JSONValue.parse(String(decoding: body, as: UTF8.self))
    } catch {
        throw ModelsParseError(provider: "google", reason: "envelope: \(error)")
    }
    var records: [ParsedModelRecord] = []
    if case let .array(data)? = envelope.member("models") {
        let prefix = "models/"
        for wire in data {
            var id = wire.stringValue(at: "name")
            if id.hasPrefix(prefix) {
                id = String(id.dropFirst(prefix.count))
            }
            records.append(ParsedModelRecord(
                id: id,
                displayName: wire.stringValue(at: "displayName"),
                description: wire.stringValue(at: "description"),
                created: 0,
                contextWindow: wire.intValue(at: "inputTokenLimit"),
                maxOutput: wire.intValue(at: "outputTokenLimit"),
                raw: wire
            ))
        }
    }
    let nextCursor = envelope.stringValue(at: "nextPageToken")
    return ParsedModelsPage(records: records, nextCursor: nextCursor)
}
