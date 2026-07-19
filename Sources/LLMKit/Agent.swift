import Foundation

///
///
///
///
///
///
///
///
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

    ///
    @discardableResult
    public func addTool(_ tool: Tool) -> Agent { tools.append(tool); return self }

    ///
    @discardableResult
    public func model(_ model: String) -> Agent { modelOverride = model; return self }

    ///
    @discardableResult
    public func system(_ system: String) -> Agent { systemPrompt = system; return self }

    ///
    @discardableResult
    public func maxToolIterations(_ value: Int) -> Agent { maxToolIterations = value; return self }

    ///
    @discardableResult
    public func caching() -> Agent { options.caching = true; return self }

    ///
    @discardableResult
    public func cacheTtl(_ seconds: Int) -> Agent { options.cacheTtl = seconds; return self }

    ///
    @discardableResult
    public func addMiddleware(_ hook: @escaping MiddlewareFn) -> Agent {
        options.middleware.append(hook); return self
    }

    ///
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
            //
            let llmEvent = Event(op: .llmRequest, provider: provider.rawValue, model: model)
            let llmStart = Date()
            try Middleware.firePre(options.middleware, llmEvent)

            var llmPost = llmEvent
            let raw: JSONValue
            let parsed: Response
            do {
                //
                //
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
                Middleware.setError(&llmPost, error)
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
                //
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
