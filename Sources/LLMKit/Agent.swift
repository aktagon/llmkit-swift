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
        var totalUsage = Usage(input: 0, output: 0, cacheWrite: 0, cacheRead: 0, reasoning: 0, cost: 0)

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
                parsed = try ResponseParser.parse(config: config, body: data)
            } catch {
                llmPost.duration = Date().timeIntervalSince(llmStart)
                llmPost.err = Middleware.errString(error)
                Middleware.firePost(options.middleware, llmPost)
                throw error
            }
            llmPost.duration = Date().timeIntervalSince(llmStart)
            llmPost.usage = parsed.usage
            Middleware.firePost(options.middleware, llmPost)
            accumulate(&totalUsage, parsed.usage)

            let calls = Transforms.extractToolCalls(raw, config)
            if calls.isEmpty {
                history.append(.text(role: "assistant", text: parsed.text))
                return Response(
                    text: parsed.text, usage: totalUsage,
                    finishReason: parsed.finishReason, finishMessage: parsed.finishMessage, raw: nil
                )
            }

            history.append(.calls(calls))
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

    private func accumulate(_ total: inout Usage, _ delta: Usage) {
        total.input += delta.input
        total.output += delta.output
        total.cacheWrite += delta.cacheWrite
        total.cacheRead += delta.cacheRead
        total.reasoning += delta.reasoning
        total.cost += delta.cost
    }
}
