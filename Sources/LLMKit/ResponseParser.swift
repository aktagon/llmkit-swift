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
    // Cache-token and cost paths live in the generated Caching / Response
    // fact tables (mirroring Rust), not on ProviderSpec.
    let (cacheWritePath, cacheReadPath) = cacheUsagePaths(config.name)
    let costPath = usageCostPath(config.name)

    let usage = Usage(
        input: raw.intValue(at: config.usageInputPath),
        output: raw.intValue(at: config.usageOutputPath),
        cacheWrite: cacheWritePath.isEmpty ? 0 : raw.intValue(at: cacheWritePath),
        cacheRead: cacheReadPath.isEmpty ? 0 : raw.intValue(at: cacheReadPath),
        reasoning: config.reasoningTokensPath.isEmpty ? 0 : raw.intValue(at: config.reasoningTokensPath),
        cost: costPath.isEmpty
            ? 0.0
            : raw.doubleValue(at: costPath) * usageCostScale(config.name)
    )

    return Response(
        text: raw.stringValue(at: config.responseTextPath),
        usage: usage,
        finishReason: config.finishReasonPath.isEmpty ? "" : raw.stringValue(at: config.finishReasonPath),
        finishMessage: config.finishMessagePath.isEmpty ? "" : raw.stringValue(at: config.finishMessagePath),
        raw: nil
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
    JSONObject.setWirePath(&raw, config.usageInputPath, .int(Int64(response.usage.input)))
    JSONObject.setWirePath(&raw, config.usageOutputPath, .int(Int64(response.usage.output)))
    JSONObject.setWirePath(&raw, cacheWritePath, .int(Int64(response.usage.cacheWrite)))
    JSONObject.setWirePath(&raw, cacheReadPath, .int(Int64(response.usage.cacheRead)))
    JSONObject.setWirePath(&raw, config.reasoningTokensPath, .int(Int64(response.usage.reasoning)))
    if costScale != 0 {
        JSONObject.setWirePath(&raw, costPath, .double(response.usage.cost / costScale))
    }
    JSONObject.setWirePath(&raw, config.finishReasonPath, .string(response.finishReason))
    JSONObject.setWirePath(&raw, config.finishMessagePath, .string(response.finishMessage))
    return Data(JSONValue.object(raw).serialized().utf8)
}

/// Refuses to encode a canonical field whose mapping is `OneWay` for this
/// provider — the result set of CQ-WMAP-011 (ADR-076 SYM-007). Only one member
/// is in Phase 2's scope; the other, `exceptGoogleToolCallID`, covers tool
/// calls, which are out (SYM-008).
///
/// An empty value is not an error: there is nothing to write, so the common path
/// stays usable and only the lying path fails. `field` and `message` carry the
/// mapping's `canonicalPath` and `invertibilityNote` verbatim.
func guardOneWayFields(_ provider: ProviderName, _ response: Response) throws {
    if provider == .vertex, !response.finishReason.isEmpty {
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
        usage: Usage(
            input: raw.intValue(at: "usage.input_tokens"),
            output: raw.intValue(at: "usage.output_tokens"),
            cacheRead: raw.intValue(at: "usage.input_tokens_details.cached_tokens"),
            reasoning: raw.intValue(at: "usage.output_tokens_details.reasoning_tokens")
        ),
        finishReason: raw.stringValue(at: "status"),
        finishMessage: "",
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
    JSONObject.setWirePath(&raw, "usage.input_tokens", .int(Int64(response.usage.input)))
    JSONObject.setWirePath(&raw, "usage.output_tokens", .int(Int64(response.usage.output)))
    JSONObject.setWirePath(&raw, "usage.input_tokens_details.cached_tokens", .int(Int64(response.usage.cacheRead)))
    JSONObject.setWirePath(&raw, "usage.output_tokens_details.reasoning_tokens", .int(Int64(response.usage.reasoning)))
    JSONObject.setWirePath(&raw, "status", .string(response.finishReason))
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
