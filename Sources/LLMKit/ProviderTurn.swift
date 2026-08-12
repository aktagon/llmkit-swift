import Foundation

/// Verbatim assistant-turn capture (ADR-085).
///
/// llmkit keeps a canonical projection of every turn — role, content, tool calls
/// — and used to rebuild the next request's assistant turn from it. That
/// projection is lossy in three ways (ADR-085 §1): it has nowhere to put
/// reasoning, it drops assistant prose that accompanies a tool call, and it has
/// no slot for per-part provider metadata. The fix is not a richer projection but
/// a second representation alongside it: keep the provider's own bytes for the
/// turn and send those back unchanged.
///
/// Nothing here parses the payload. The only structure this file reads is the
/// path down to the turn — everything at and below it is carried as the provider
/// wrote it.
///
/// Swift-specific note. `JSONValue.parse` produces a tree with no memory of the
/// source text, so capture SLICES the response text instead: the walk below finds
/// the span of the value at the path and keeps that substring. On the SEND leg the
/// splice re-parses that string into a `JSONValue`, because that is the type the
/// request body is assembled in — object key order survives (`JSONValue.object`
/// is an ordered pair list), which is what ADR-085 RSN-002's amendment permits
/// (verbatim at REST is the guarantee; byte-identical transmission is a Go-only
/// property).
enum ProviderTurnCapture {
    private static let whitespace: Set<Character> = [" ", "\t", "\n", "\r"]

    /// Splits one dot-notation path segment into a field name and an array index:
    /// `"choices[0]"` -> `("choices", 0)`; `"message"` -> `("message", nil)`.
    ///
    ///
    /// single parser here, so capture cannot drift from the path facts it reads. A
    /// malformed segment yields the whole segment as a field name and no index,
    /// which resolves to "no such field" one step later — never a silently widened
    /// match to the whole array, which is what a negative index would read back as.
    static func splitPathSegment(_ part: String) -> (String, Int?) {
        guard let bracket = part.firstIndex(of: "["), part.hasSuffix("]") else {
            return (part, nil)
        }
        let inner = String(part[part.index(after: bracket)..<part.index(before: part.endIndex)])
        guard !inner.isEmpty, inner.allSatisfy(\.isNumber), let index = Int(inner) else {
            return (part, nil)
        }
        return (String(part[part.startIndex..<bracket]), index)
    }

    private static func skipWhitespace(_ chars: [Character], _ i: Int) -> Int {
        var i = i
        while i < chars.count, whitespace.contains(chars[i]) { i += 1 }
        return i
    }

    /// The index just past the JSON string starting at `i`, or nil.
    private static func skipString(_ chars: [Character], _ i: Int) -> Int? {
        guard i < chars.count, chars[i] == "\"" else { return nil }
        var i = i + 1
        while i < chars.count {
            if chars[i] == "\\" {
                i += 2
                continue
            }
            if chars[i] == "\"" { return i + 1 }
            i += 1
        }
        return nil
    }

    /// The index just past the JSON value starting at `i`, or nil when the text
    /// there is not a value. Objects and arrays are walked by nesting depth, which
    /// is why the string scan above has to be exact — a `}` inside a string must
    /// not close an object.
    private static func skipValue(_ chars: [Character], _ i: Int) -> Int? {
        var i = skipWhitespace(chars, i)
        guard i < chars.count else { return nil }
        if chars[i] == "\"" { return skipString(chars, i) }
        if chars[i] == "{" || chars[i] == "[" {
            var depth = 0
            while i < chars.count {
                let c = chars[i]
                if c == "\"" {
                    guard let end = skipString(chars, i) else { return nil }
                    i = end
                    continue
                }
                if c == "{" || c == "[" {
                    depth += 1
                } else if c == "}" || c == "]" {
                    depth -= 1
                    if depth == 0 { return i + 1 }
                }
                i += 1
            }
            return nil
        }
        // A literal or number: everything up to the next structural character.
        let start = i
        while i < chars.count, chars[i] != ",", chars[i] != "}", chars[i] != "]",
              !whitespace.contains(chars[i]) {
            i += 1
        }
        return i > start ? i : nil
    }

    /// The half-open span of `field`'s value in the object beginning at `start`.
    private static func spanOfMember(
        _ chars: [Character], _ start: Int, _ field: String
    ) -> (Int, Int)? {
        var i = skipWhitespace(chars, start)
        guard i < chars.count, chars[i] == "{" else { return nil }
        i += 1
        while true {
            i = skipWhitespace(chars, i)
            guard i < chars.count, chars[i] != "}" else { return nil }
            guard let keyEnd = skipString(chars, i) else { return nil }
            // The key is a JSON string, so the SDK's own parser decodes its escapes.
            guard case let .string(key)? = try? JSONValue.parse(String(chars[i..<keyEnd]))
            else { return nil }
            i = skipWhitespace(chars, keyEnd)
            guard i < chars.count, chars[i] == ":" else { return nil }
            let valueStart = skipWhitespace(chars, i + 1)
            guard let valueEnd = skipValue(chars, valueStart) else { return nil }
            if key == field { return (valueStart, valueEnd) }
            i = skipWhitespace(chars, valueEnd)
            guard i < chars.count, chars[i] == "," else { return nil }
            i += 1
        }
    }

    /// The half-open span of element `index` in the array beginning at `start`.
    private static func spanOfElement(
        _ chars: [Character], _ start: Int, _ index: Int
    ) -> (Int, Int)? {
        var i = skipWhitespace(chars, start)
        guard i < chars.count, chars[i] == "[" else { return nil }
        i += 1
        var position = 0
        while true {
            i = skipWhitespace(chars, i)
            guard i < chars.count, chars[i] != "]" else { return nil }
            guard let valueEnd = skipValue(chars, i) else { return nil }
            if position == index { return (i, valueEnd) }
            position += 1
            i = skipWhitespace(chars, valueEnd)
            guard i < chars.count, chars[i] == "," else { return nil }
            i += 1
        }
    }

    /// The VERBATIM JSON text of the value at `path`, or nil when the path does
    /// not resolve.
    ///
    /// The distinction from `JSONValue.value(at:)` is the whole point: that walker
    /// descends a parsed tree, so re-serializing its result emits the SDK's
    /// rendering of the value rather than the provider's.
    static func extractRawJSONPath(_ text: String, _ path: String) -> String? {
        guard !path.isEmpty else { return nil }
        let chars = Array(text)
        var start = 0
        var end = chars.count
        for part in path.split(separator: ".", omittingEmptySubsequences: false) {
            let (field, index) = splitPathSegment(String(part))
            if !field.isEmpty {
                guard let span = spanOfMember(chars, start, field) else { return nil }
                (start, end) = span
            }
            if let index {
                guard let span = spanOfElement(chars, start, index) else { return nil }
                (start, end) = span
            }
        }
        return String(chars[start..<end])
    }

    /// Where one replayable assistant turn sits in a response body for this
    /// provider under this wire shape, or `""` when the shape declares no position.
    ///
    /// An empty result is a DECLARED absence, not a missing lookup:
    /// `ChatBedrock` carries `assistantTurnUnanchored` rather than a path,
    /// because nobody has probed what an assistant turn looks like on Converse
    ///
    /// `""` here always means "declared unanchored" and never "somebody forgot".
    static func assistantTurnPath(_ config: ProviderSpec, _ chatWireShape: String) -> String {
        config.chatProtocols.first { $0.wireShape == chatWireShape }?.assistantTurnPath ?? ""
    }

    /// The shape a response was produced under. An empty argument means the caller
    /// did not route through `Protocol(...)` — the batch path passes `""` because
    /// batch is Chat-Completions-only (ADR-055) — so the provider's default shape
    /// applies.
    private static func effectiveChatWireShape(
        _ config: ProviderSpec, _ chatWireShape: String
    ) -> String {
        chatWireShape.isEmpty ? config.chatWireShape : chatWireShape
    }

    /// Lifts the assistant turn out of a response body, or returns nil when this
    /// shape declares no turn position or the body carries nothing there.
    static func capture(
        _ text: String, _ config: ProviderSpec, _ chatWireShape: String
    ) -> ProviderTurn? {
        let shape = effectiveChatWireShape(config, chatWireShape)
        guard let wire = extractRawJSONPath(text, assistantTurnPath(config, shape))
        else { return nil }
        // A JSON null at the path is the provider declining to send a turn, not a
        // turn whose content is null — Google nulls candidates[0].content on a
        // safety block, and OpenAI-compatible proxies null choices[0].message on a
        // content filter. A bare `null` is four characters of a perfectly good JSON
        // value, so an emptiness check alone captures it and the next request
        // appends a bare null to the message array, which is a 400.
        let trimmed = wire.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "null" { return nil }
        return ProviderTurn(wireShape: shape, wire: wire)
    }

    /// The RSN-006 boundary: a captured payload is replayed only under the shape
    /// that produced it, and a mismatch drops it and reconstructs the turn from the
    /// canonical projection instead.
    ///
    /// One unconditional rule, applied once per request where the config and the
    /// message list first meet, so no transform has to remember the check. The
    /// draft ADR made this branch on whether the provider mandates the echo and
    /// raised an error on the mandating ones; RESEARCH-017 measured that set to be
    /// empty, so only the drop arm was ever reachable.
    ///
    /// Dropping is the safe direction here, and the measurement is why: every
    /// probed provider ACCEPTS a request with the payload omitted, while a mangled
    /// payload is the single 400 anywhere in the matrix. Replaying an Anthropic
    /// block array into Google's contents array would be exactly that mangling.
    static func resolveTurns(
        _ msgs: [Transforms.Msg], _ config: ProviderSpec, _ wireShape: String
    ) -> [Transforms.Msg] {
        msgs.map { msg in
            // Two conditions, not one. Matching the shape is not enough: the shape
            // must also DECLARE a turn position. A payload claiming an unanchored
            // shape can only come from caller-supplied data, and the transform for
            // such a shape has no replay arm — so without the second check, a
            // history carrying a ChatBedrock payload reaches a builder with nowhere
            // to put it.
            guard case let .turn(shape, _, fallback) = msg else { return msg }
            if shape == wireShape, !assistantTurnPath(config, shape).isEmpty { return msg }
            return fallback
        }
    }
}
