import Foundation

/// Extracts text and usage from a provider response body into the universal
/// `Response`, reading every field from the per-provider dotted paths declared
/// on the generated `ProviderSpec` and the Caching / Response fact tables.
/// `chatWireShape` is the EFFECTIVE wire shape for this request (after
/// `Protocol(...)` resolution, ADR-055): only `ChatResponsesOpenAI` diverges
/// (the `output[]` envelope); every other value uses the provider's declared
/// response paths.
///
/// Keyless, IO-free and pure (ADR-076 SYM-002): no `Client`, no credential, no
/// network, no clock. The wire shape is required, not derived — one provider can
/// serve two chat protocols, and inferring it silently mis-parses (SYM-003).
/// This is the same function the chat send path calls (SYM-004).
public func decodeResponse(
    _ provider: ProviderName, _ chatWireShape: String, _ body: Data
) throws -> Response {
    guard let text = String(data: body, encoding: .utf8) else {
        throw LLMKitError.decoding("response body is not valid UTF-8")
    }
    let raw = try JSONValue.parse(text)

    if chatWireShape == "ChatResponsesOpenAI" {
        return parseResponsesEnvelope(raw)
    }

    let config = providerConfig(provider)
    return Response(
        text: raw.stringValue(at: config.responseTextPath),
        usage: decodeUsage(raw, provider),
        finishReason: raw.optString(at: config.finishReasonPath),
        finishMessage: raw.optString(at: config.finishMessagePath),
        raw: nil
    )
}

/// Reads every canonical `Usage` dimension out of a provider response body.
/// The ONE usage reader (ADR-076 SYM-004): the codec, the chat send path and
/// the agent loop all call this, so a dimension cannot be read in one place and
/// forgotten in another — which is how the agent loop came to accumulate a
/// subset of the six across the SDK pack (BUG-045).
///
/// A dimension is `nil` when the provider declares no path for it OR the
/// response did not carry it. Neither is zero.
func decodeUsage(_ raw: JSONValue, _ provider: ProviderName) -> Usage {
    let config = providerConfig(provider)
    // Cache-token and cost paths live in the generated Caching / Response
    // fact tables (mirroring Rust), not on ProviderSpec.
    let (cacheWritePath, cacheReadPath) = cacheUsagePaths(config.name)
    return Usage(
        input: raw.optInt(at: config.usageInputPath),
        output: raw.optInt(at: config.usageOutputPath),
        cacheWrite: raw.optInt(at: cacheWritePath),
        cacheRead: raw.optInt(at: cacheReadPath),
        reasoning: raw.optInt(at: config.reasoningTokensPath),
        // Scaling PRESERVES absence: an unreported cost stays unreported
        // rather than becoming `0.0 * scale` (AVAIL-007).
        cost: raw.optDouble(at: usageCostPath(config.name))
            .map { $0 * usageCostScale(config.name) }
    )
}

/// Adds two `Usage` values dimension-wise, ABSORBING per dimension
/// (ADR-081 AVAIL-005): a total is only reported when EVERY summand reported
/// it. Summing the turns that happened to report a dimension and presenting
/// that as the total is the original defect at aggregate scale.
func accumulateUsage(_ total: Usage, _ turn: Usage) -> Usage {
    func add<T: AdditiveArithmetic>(_ a: T?, _ b: T?) -> T? {
        guard let a, let b else { return nil }
        return a + b
    }
    return Usage(
        input: add(total.input, turn.input),
        output: add(total.output, turn.output),
        cacheWrite: add(total.cacheWrite, turn.cacheWrite),
        cacheRead: add(total.cacheRead, turn.cacheRead),
        reasoning: add(total.reasoning, turn.reasoning),
        cost: add(total.cost, turn.cost)
    )
}

/// `decodeResponse`'s inverse: renders a canonical `Response` back onto the wire
/// for `provider` + `chatWireShape`. Every write location comes from the same
/// generated path accessors `decodeResponse` reads — there is no second table
/// and no path literal here (ADR-076 SYM-005).
///
/// Keyless, IO-free and pure, like its mirror. The result is NOT byte-identical
/// to the body a provider would send: a provider body carries fields the
/// canonical `Response` does not model (ADR-014's `raw` exists for exactly
/// that). The contract is the canonical fixed point,
/// `decode(encode(decode(b))) == decode(b)` (SYM-006).
public func encodeResponse(
    _ provider: ProviderName, _ chatWireShape: String, _ response: Response
) throws -> Data {
    try guardOneWayFields(provider, response)
    if chatWireShape == "ChatResponsesOpenAI" {
        return Data(JSONValue.object(encodeResponsesEnvelope(response)).serialized().utf8)
    }

    let config = providerConfig(provider)
    let (cacheWritePath, cacheReadPath) = cacheUsagePaths(config.name)
    let costPath = usageCostPath(config.name)
    let costScale = usageCostScale(config.name)

    var raw: [(String, JSONValue)] = []
    JSONObject.setWirePath(&raw, config.responseTextPath, .string(response.text))
    JSONObject.setWirePath(&raw, config.usageInputPath, wire(response.usage.input))
    JSONObject.setWirePath(&raw, config.usageOutputPath, wire(response.usage.output))
    JSONObject.setWirePath(&raw, cacheWritePath, wire(response.usage.cacheWrite))
    JSONObject.setWirePath(&raw, cacheReadPath, wire(response.usage.cacheRead))
    JSONObject.setWirePath(&raw, config.reasoningTokensPath, wire(response.usage.reasoning))
    if costScale != 0 {
        JSONObject.setWirePath(&raw, costPath, wire(response.usage.cost.map { $0 / costScale }))
    }
    JSONObject.setWirePath(&raw, config.finishReasonPath, wire(response.finishReason))
    JSONObject.setWirePath(&raw, config.finishMessagePath, wire(response.finishMessage))
    return Data(JSONValue.object(raw).serialized().utf8)
}

/// A parsed signal string as an optional canonical field: an empty extraction
/// means the provider declared no path or sent no value, which is absence, not
/// the empty string. Swift promotes `String` to `String?` implicitly, so a bare
/// `""` would compile and store a REPORTED empty string — the wrong side of the
/// very distinction ADR-081 draws. Media parsers build a `String` accumulator
/// and pass it through here at the container boundary.
func optString(_ value: String) -> String? { value.isEmpty ? nil : value }

// An unreported canonical field becomes `.null`, which `setWirePath` skips;
// a reported value — zero included — becomes a real JSON value and is written.
func wire(_ value: Int?) -> JSONValue { value.map { .int(Int64($0)) } ?? .null }
func wire(_ value: Double?) -> JSONValue { value.map { .double($0) } ?? .null }
func wire(_ value: String?) -> JSONValue { value.map { .string($0) } ?? .null }

/// Refuses to encode a canonical field whose mapping is `OneWay` for this
/// provider — the result set of CQ-WMAP-011 (ADR-076 SYM-007). Only one member
/// is in Phase 2's scope; the other, `exceptGoogleToolCallID`, covers tool
/// calls, which are out (SYM-008).
///
/// An empty value is not an error: there is nothing to write, so the common path
/// stays usable and only the lying path fails. `field` and `message` carry the
/// mapping's `canonicalPath` and `invertibilityNote` verbatim.
func guardOneWayFields(_ provider: ProviderName, _ response: Response) throws {
    // Non-empty, not merely present: the guard exists to refuse FABRICATION, and
    // neither an unreported field nor a reported empty one would write anything
    // (see `isEmptyWireValue`). Only a value that would reach the wire lies.
    if provider == .vertex, let reason = response.finishReason, !reason.isEmpty {
        throw LLMKitError.validation(
            field: "response.finish_reason",
            message: "Vertex carries no finish-reason field. Its path reads predictions[0].raiFilteredReason — a safety-filter explanation surfaced AS the finish reason. Extraction is a deliberate fusion, so the reverse leg cannot decide whether a given canonical finish_reason originated as a safety verdict, and writing an ordinary stop signal into that field would fabricate one."
        )
    }
}

/// Extracts text + usage from OpenAI's Responses reply (ADR-055). Unlike Chat
/// Completions (`choices[].message.content`), the reply is an `output[]` array
/// whose message item carries `content[]` blocks of type "output_text"; usage is
/// input_tokens/output_tokens with cached + reasoning sub-details. Hand-coded
/// per wire shape, symmetric with the `transformResponsesInput` request arm
/// (ADR-028: behavior held by tests, not by declared response paths).
func parseResponsesEnvelope(_ raw: JSONValue) -> Response {
    Response(
        text: extractResponsesText(raw),
        // The Responses envelope carries no cache-write or cost field at all.
        // That is not a zero: it is the provider never making the claim.
        usage: Usage(
            input: raw.optInt(at: "usage.input_tokens"),
            output: raw.optInt(at: "usage.output_tokens"),
            cacheRead: raw.optInt(at: "usage.input_tokens_details.cached_tokens"),
            reasoning: raw.optInt(at: "usage.output_tokens_details.reasoning_tokens")
        ),
        finishReason: raw.optString(at: "status"),
        finishMessage: nil,
        raw: nil
    )
}

/// Mirror of `parseResponsesEnvelope`: rebuilds OpenAI's Responses reply
/// (ADR-055). Hand-coded per wire shape on both legs, symmetric with the reader,
/// for the same reason the reader is.
func encodeResponsesEnvelope(_ response: Response) -> [(String, JSONValue)] {
    var raw: [(String, JSONValue)] = []
    if !response.text.isEmpty {
        raw.append(("output", .array([.object([
            ("type", .string("message")),
            ("content", .array([.object([
                ("type", .string("output_text")),
                ("text", .string(response.text)),
            ])])),
        ])])))
    }
    JSONObject.setWirePath(&raw, "usage.input_tokens", wire(response.usage.input))
    JSONObject.setWirePath(&raw, "usage.output_tokens", wire(response.usage.output))
    JSONObject.setWirePath(&raw, "usage.input_tokens_details.cached_tokens", wire(response.usage.cacheRead))
    JSONObject.setWirePath(&raw, "usage.output_tokens_details.reasoning_tokens", wire(response.usage.reasoning))
    JSONObject.setWirePath(&raw, "status", wire(response.finishReason))
    return raw
}

/// Walks the Responses `output[]` array for the first message item and returns
/// its first `output_text` block. Iterating (rather than a fixed
/// output[0].content[0] path) tolerates a leading reasoning item.
func extractResponsesText(_ raw: JSONValue) -> String {
    guard case let .array(output)? = raw.member("output") else { return "" }
    for item in output {
        guard case .string("message")? = item.member("type"),
              case let .array(content)? = item.member("content") else { continue }
        for block in content {
            guard case .string("output_text")? = block.member("type"),
                  case let .string(text)? = block.member("text") else { continue }
            return text
        }
    }
    return ""
}

/// Maps a non-2xx response to a typed API error, reading the message from the
/// provider's declared `errorMessagePath` when the body parses as JSON, falling
/// back to the raw body.
enum ResponseParser {
    static func parseError(config: ProviderSpec, statusCode: Int, body: Data) -> LLMKitError {
        let raw = String(data: body, encoding: .utf8) ?? ""
        var message = raw
        if !config.errorMessagePath.isEmpty,
           let parsed = try? JSONValue.parse(raw) {
            let extracted = parsed.stringValue(at: config.errorMessagePath)
            if !extracted.isEmpty { message = extracted }
        }
        return .api(provider: config.slug, statusCode: statusCode, message: message)
    }
}
