import Foundation

/// The tool-using agent loop — a port of Rust's `agent.rs`. The one stateful
/// builder (ADR-066 SWIFT-004): a reference type that accumulates conversation
/// history across turns. Each `prompt` runs the tool loop, calling registered
/// tools until the model returns a plain-text answer (or `maxToolIterations` is
/// hit). The request body is built through the shared `RequestBuilder`, so the
/// agent constructs no wire shape of its own. Not thread-safe: confine one
/// `Agent` to one task/conversation (not `Sendable` — the compiler enforces
/// this under strict concurrency).
public final class Agent {
    private let provider: ProviderName
    private let apiKey: String
    private let baseURLOverride: String?
    private let http: HTTPClient
    private var modelOverride: String?
    private var systemPrompt: String?
    private var options = PromptOptions()
    private var tools: [Tool] = []
    private var history: [Transforms.Msg] = []
    private var maxToolIterations = 10
    private var rawOptIn = false

    init(provider: ProviderName, apiKey: String, baseURLOverride: String?, http: HTTPClient) {
        self.provider = provider
        self.apiKey = apiKey
        self.baseURLOverride = baseURLOverride
        self.http = http
    }

    /// Register a tool the model may invoke. Returns self for chaining.
    @discardableResult
    public func addTool(_ tool: Tool) -> Agent { tools.append(tool); return self }

    /// Select the model. Returns self for chaining.
    @discardableResult
    public func model(_ model: String) -> Agent { modelOverride = model; return self }

    /// Set the system instruction. Returns self for chaining.
    @discardableResult
    public func system(_ system: String) -> Agent { systemPrompt = system; return self }

    /// Cap the number of tool-loop iterations (default 10). Returns self.
    @discardableResult
    public func maxToolIterations(_ value: Int) -> Agent { maxToolIterations = value; return self }

    /// Opt into prompt caching (ADR-026) — applied on every turn (BUG-004).
    @discardableResult
    public func caching() -> Agent { options.caching = true; return self }

    /// Set the cache TTL in seconds (resource caching only). Returns self.
    @discardableResult
    public func cacheTtl(_ seconds: Int) -> Agent { options.cacheTtl = seconds; return self }

    /// Register a middleware hook (observation + pre-phase veto). Returns self.
    @discardableResult
    public func addMiddleware(_ hook: @escaping MiddlewareFn) -> Agent {
        options.middleware.append(hook); return self
    }

    /// Set the maximum number of output tokens per turn. Returns self.
    @discardableResult
    public func maxTokens(_ maxTokens: Int) -> Agent { options.maxTokens = maxTokens; return self }

    /// Set the sampling temperature. Returns self.
    @discardableResult
    public func temperature(_ value: Double) -> Agent { options.temperature = value; return self }

    /// Set nucleus-sampling top-p. Returns self.
    @discardableResult
    public func topP(_ value: Double) -> Agent { options.topP = value; return self }

    /// Set top-k sampling. Returns self.
    @discardableResult
    public func topK(_ value: Int) -> Agent { options.topK = value; return self }

    /// Set the sampling seed. Returns self.
    @discardableResult
    public func seed(_ value: Int) -> Agent { options.seed = Int64(value); return self }

    /// Set the frequency penalty. Returns self.
    @discardableResult
    public func frequencyPenalty(_ value: Double) -> Agent { options.frequencyPenalty = value; return self }

    /// Set the presence penalty. Returns self.
    @discardableResult
    public func presencePenalty(_ value: Double) -> Agent { options.presencePenalty = value; return self }

    /// Set the extended-thinking token budget. Returns self.
    @discardableResult
    public func thinkingBudget(_ value: Int) -> Agent { options.thinkingBudget = value; return self }

    /// Set the reasoning effort level. Returns self.
    @discardableResult
    public func reasoningEffort(_ value: String) -> Agent { options.reasoningEffort = value; return self }

    /// Set the stop sequences. Returns self.
    @discardableResult
    public func stopSequences(_ values: [String]) -> Agent { options.stopSequences = values; return self }

    /// Set the per-category safety thresholds (Google). Returns self.
    @discardableResult
    public func safetySettings(_ values: [SafetySetting]) -> Agent { options.safetySettings = values; return self }

    /// Replace the conversation history with `msgs`. The next `prompt` sends
    /// these turns before its own user turn.
    ///
    /// ADR-085 RSN-005 — a message you author here carries no captured
    /// provider payload, so an assistant turn with tool calls is rebuilt from
    /// its role, content and tool calls alone. To preserve provider reasoning,
    /// pass back the messages this SDK produced.
    @discardableResult
    public func history(_ msgs: Message...) -> Agent {
        history = Transforms.msgs(from: msgs); return self
    }

    /// Opt into the parsed provider body of the last turn on the final
    /// `Response.raw` (ADR-014). Returns self.
    @discardableResult
    public func raw() -> Agent { rawOptIn = true; return self }

    /// Append a user turn and run the tool loop to a final text answer.
    @discardableResult
    public func prompt(_ message: String) async throws -> Response {
        history.append(.text(role: "user", text: message))
        return try await runToolLoop()
    }

    private func runToolLoop() async throws -> Response {
        let config = providerConfig(provider)
        let model = try RequestBuilder.resolveModel(config, modelOverride)
        let url = RequestBuilder.buildURL(
            config: config, endpoint: config.endpoint, apiKey: apiKey, model: model, baseURLOverride: baseURLOverride
        )
        // Seeded from the first turn, not from an all-zero literal: absorbing
        // addition's identity is a REPORTED zero, so seeding with six reported
        // zeroes would claim every dimension was reported even when no turn
        // reported any (ADR-081 AVAIL-005).
        var totalUsage: Usage?

        for _ in 0..<maxToolIterations {
            // Fire llmRequest middleware around each turn of the loop.
            let llmEvent = Event(op: .llmRequest, provider: provider.rawValue, model: model)
            let llmStart = Date()
            try Middleware.firePre(options.middleware, llmEvent)

            var llmPost = llmEvent
            let raw: JSONValue
            let parsed: Response
            do {
                // Caching is a shared request-construction step (ADR-026 / BUG-004):
                // applied on every agent turn by construction, like the Text path.
                var (body, headers) = try RequestBuilder.buildBody(
                    config: config, wireShape: config.chatWireShape, apiKey: apiKey,
                    model: model, system: systemPrompt, msgs: history, tools: tools, options: options
                )
                try await CachingRuntime.apply(
                    &body, provider: provider, model: model, apiKey: apiKey,
                    options: options, config: config, http: http, baseURLOverride: baseURLOverride
                )
                let (status, data) = try await RequestBuilder.send(
                    config: config, url: url, body: body, headers: headers, apiKey: apiKey, http: http
                )
                guard (200..<300).contains(status) else {
                    throw ResponseParser.parseError(config: config, statusCode: status, body: data)
                }
                raw = try JSONValue.parse(String(decoding: data, as: UTF8.self))
                parsed = try decodeResponse(provider, config.chatWireShape, data)
            } catch {
                llmPost.duration = Date().timeIntervalSince(llmStart)
                Middleware.setError(&llmPost, error)
                Middleware.firePost(options.middleware, llmPost)
                throw error
            }
            llmPost.duration = Date().timeIntervalSince(llmStart)
            llmPost.usage = parsed.usage
            Middleware.firePost(options.middleware, llmPost)
            totalUsage = totalUsage.map { accumulateUsage($0, parsed.usage) } ?? parsed.usage

            let calls = Transforms.extractToolCalls(raw, config)
            if calls.isEmpty {
                // The terminal turn is captured too: an agent kept alive for another
                // prompt replays it like any other, and Response carries it so a
                // caller running their own loop can thread the turn forward without
                // parsing raw per provider (ADR-085 § 6).
                history.append(
                    replayable(.text(role: "assistant", text: parsed.text), parsed.providerTurn)
                )
                let final = Response(
                    text: parsed.text, usage: totalUsage ?? Usage(),
                    finishReason: parsed.finishReason, finishMessage: parsed.finishMessage,
                    raw: nil, providerTurn: parsed.providerTurn
                )
                return attachRaw(final, raw: rawOptIn) { raw }
            }

            // Record the assistant turn. The calls are the projection the loop runs
            // tools from; the payload is the same turn as the provider wrote it, and
            // is what the NEXT request sends (ADR-085). Before this, the turn was
            // rebuilt from the calls alone, which silently dropped any prose the
            // model emitted alongside them.
            history.append(replayable(.calls(calls), parsed.providerTurn))
            for call in calls {
                // Fire toolCall middleware around each tool invocation.
                var args: [String: JSONValue] = [:]
                if case let .object(pairs)? = call.input {
                    args = Dictionary(pairs, uniquingKeysWith: { first, _ in first })
                }
                let toolEvent = Event(
                    op: .toolCall, provider: provider.rawValue, model: model, tool: call.name, args: args
                )
                let toolStart = Date()
                try Middleware.firePre(options.middleware, toolEvent)

                let content: String
                if let tool = tools.first(where: { $0.name == call.name }) {
                    do { content = try await tool.run(call.input ?? .object([])) }
                    catch { content = "error: \(error)" }
                } else {
                    content = "error: unknown tool \(call.name)"
                }

                var toolPost = toolEvent
                toolPost.result = content
                toolPost.duration = Date().timeIntervalSince(toolStart)
                Middleware.firePost(options.middleware, toolPost)

                history.append(.result(ToolResult(toolUseId: call.id, content: content)))
            }
        }
        throw LLMKitError.unsupported("max tool iterations (\(maxToolIterations)) reached")
    }

    /// Wraps a projected turn with the provider's own serialization of it, when the
    /// response carried one (ADR-085). Without a payload the projection is the turn,
    /// exactly as before this ADR.
    private func replayable(_ projected: Transforms.Msg, _ turn: ProviderTurn?) -> Transforms.Msg {
        guard let turn else { return projected }
        return .turn(shape: turn.wireShape, wire: turn.wire, fallback: projected)
    }
}
