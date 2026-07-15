import Foundation

/// The entry point to the SDK. An immutable value type; builders reached from it
/// clone on chain (ADR-066 SWIFT-004). Phase 2 exposes the `text` builder's
/// non-streaming `prompt` terminal at full ChatCompletion parity (options,
/// structured output, the Responses protocol).
public struct Client: Sendable {
    let provider: ProviderName
    let apiKey: String
    let baseURLOverride: String?
    let http: HTTPClient

    /// Create a client for a provider. `session` is injected so callers (and
    /// tests) control the transport.
    public init(provider: ProviderName, apiKey: String, session: URLSession = .shared) {
        self.provider = provider
        self.apiKey = apiKey
        self.baseURLOverride = nil
        self.http = HTTPClient(session: session)
    }

    private init(provider: ProviderName, apiKey: String, baseURLOverride: String?, http: HTTPClient) {
        self.provider = provider
        self.apiKey = apiKey
        self.baseURLOverride = baseURLOverride
        self.http = http
    }

    /// Convenience constructor for OpenAI.
    public static func openai(apiKey: String, session: URLSession = .shared) -> Client {
        Client(provider: .openai, apiKey: apiKey, session: session)
    }

    /// Override the provider base URL — the caller-substituted seam for
    /// account/project/region-in-URL providers (ADR-035) and the test transport.
    public func baseURL(_ url: String) -> Client {
        Client(provider: provider, apiKey: apiKey, baseURLOverride: url, http: http)
    }

    /// The text-generation builder.
    public var text: Text {
        Text(provider: provider, apiKey: apiKey, baseURLOverride: baseURLOverride, http: http)
    }

    /// The image-generation builder.
    public var image: Image {
        Image(provider: provider, apiKey: apiKey, baseURLOverride: baseURLOverride, http: http)
    }

    /// A fresh tool-using agent (the one stateful builder, ADR-066 SWIFT-004).
    public func agent() -> Agent {
        Agent(provider: provider, apiKey: apiKey, baseURLOverride: baseURLOverride, http: http)
    }
}

/// Immutable, clone-on-chain builder for text generation.
public struct Text: Sendable {
    let provider: ProviderName
    let apiKey: String
    let baseURLOverride: String?
    let http: HTTPClient
    var modelOverride: String?
    var systemPrompt: String?
    var options = PromptOptions()
    var inputImages: [InputImage] = []
    var inputFiles: [FileRef] = []

    init(provider: ProviderName, apiKey: String, baseURLOverride: String?, http: HTTPClient) {
        self.provider = provider
        self.apiKey = apiKey
        self.baseURLOverride = baseURLOverride
        self.http = http
    }

    /// Select the model.
    public func model(_ model: String) -> Text { with { $0.modelOverride = model } }

    /// Set the system instruction.
    public func system(_ system: String) -> Text { with { $0.systemPrompt = system } }

    /// Set the maximum output tokens.
    public func maxTokens(_ maxTokens: Int) -> Text { with { $0.options.maxTokens = maxTokens } }

    /// Sampling temperature.
    public func temperature(_ value: Double) -> Text { with { $0.options.temperature = value } }

    /// Nucleus-sampling probability mass.
    public func topP(_ value: Double) -> Text { with { $0.options.topP = value } }

    /// Top-k sampling cutoff.
    public func topK(_ value: Int) -> Text { with { $0.options.topK = value } }

    /// Deterministic sampling seed.
    public func seed(_ value: Int) -> Text { with { $0.options.seed = Int64(value) } }

    /// Frequency penalty.
    public func frequencyPenalty(_ value: Double) -> Text { with { $0.options.frequencyPenalty = value } }

    /// Presence penalty.
    public func presencePenalty(_ value: Double) -> Text { with { $0.options.presencePenalty = value } }

    /// Extended-thinking token budget (Anthropic / Google).
    public func thinkingBudget(_ value: Int) -> Text { with { $0.options.thinkingBudget = value } }

    /// Reasoning-effort level (provider-validated whitelist).
    public func reasoningEffort(_ value: String) -> Text { with { $0.options.reasoningEffort = value } }

    /// Stop sequences.
    public func stopSequences(_ values: [String]) -> Text { with { $0.options.stopSequences = values } }

    /// Google safety settings.
    public func safetySettings(_ values: [SafetySetting]) -> Text { with { $0.options.safetySettings = values } }

    /// Structured-output JSON Schema (as a JSON string).
    public func schema(_ schema: String) -> Text { with { $0.options.schema = schema } }

    /// Chat-protocol opt-in (ADR-055), e.g. `"responses"`.
    public func `protocol`(_ token: String) -> Text { with { $0.options.proto = token } }

    /// Opt into prompt caching (ADR-026).
    public func caching() -> Text { with { $0.options.caching = true } }

    /// Set the cache TTL in seconds (resource caching only).
    public func cacheTtl(_ seconds: Int) -> Text { with { $0.options.cacheTtl = seconds } }

    /// Register a middleware hook (observation + pre-phase veto).
    public func addMiddleware(_ hook: @escaping MiddlewareFn) -> Text {
        with { $0.options.middleware.append(hook) }
    }

    /// Attach an image as vision input to the prompt (ADR-060). The bytes are
    /// lowered into a base64 data URI and emitted as the provider's native image
    /// block. Multiple `.image(...)` calls accumulate in order.
    public func image(_ mimeType: String, _ data: Data) -> Text {
        with {
            $0.inputImages.append(InputImage(
                url: "data:\(mimeType);base64,\(data.base64EncodedString())",
                mimeType: mimeType, detail: ""
            ))
        }
    }

    /// Attach an uploaded-file reference to the prompt (ADR-060), emitted as the
    /// provider's native document/file block. Multiple `.file(...)` calls
    /// accumulate in order.
    public func file(_ id: String) -> Text {
        with { $0.inputFiles.append(FileRef(id: id, uri: "", mimeType: "")) }
    }

    /// The internal user turn: a plain text turn, or a media turn carrying the
    /// accumulated image/file parts (ADR-060). Files precede images precede text
    /// in the emitted content array.
    private func userMsgs(_ prompt: String) -> [Transforms.Msg] {
        if inputImages.isEmpty, inputFiles.isEmpty {
            return [.text(role: "user", text: prompt)]
        }
        return [.media(role: "user", text: prompt, images: inputImages, files: inputFiles)]
    }

    /// Send a single-turn prompt and return the response. Fires the `llmRequest`
    /// middleware op (pre-phase veto, post-phase observation with usage) and
    /// applies prompt caching to the built body when `.caching()` was set.
    public func prompt(_ userPrompt: String) async throws -> Response {
        let config = providerConfig(provider)
        let (wireShape, endpoint) = try RequestBuilder.resolveChatProtocol(config: config, token: options.proto)
        let model = try RequestBuilder.resolveModel(config, modelOverride)

        let baseEvent = Event(op: .llmRequest, provider: provider.rawValue, model: model)
        let start = Date()
        try Middleware.firePre(options.middleware, baseEvent)

        var postEvent = baseEvent
        do {
            var (body, headers) = try RequestBuilder.buildBody(
                config: config,
                wireShape: wireShape,
                apiKey: apiKey,
                model: model,
                system: systemPrompt,
                msgs: userMsgs(userPrompt),
                tools: [],
                options: options
            )
            try await CachingRuntime.apply(
                &body, provider: provider, model: model, apiKey: apiKey,
                options: options, config: config, http: http, baseURLOverride: baseURLOverride
            )
            let url = RequestBuilder.buildURL(
                config: config, endpoint: endpoint, apiKey: apiKey, model: model, baseURLOverride: baseURLOverride
            )
            let (statusCode, data) = try await RequestBuilder.send(
                config: config, url: url, body: body, headers: headers, apiKey: apiKey, http: http
            )
            guard (200..<300).contains(statusCode) else {
                throw ResponseParser.parseError(config: config, statusCode: statusCode, body: data)
            }
            let response = try ResponseParser.parse(config: config, body: data)
            postEvent.duration = Date().timeIntervalSince(start)
            postEvent.usage = response.usage
            Middleware.firePost(options.middleware, postEvent)
            return response
        } catch {
            postEvent.duration = Date().timeIntervalSince(start)
            postEvent.err = "\(error)"
            Middleware.firePost(options.middleware, postEvent)
            throw error
        }
    }

    /// Stream a single-turn prompt, invoking `onDelta` per text chunk, and return
    /// the assembled response (ADR-064: stream is a text execution mode).
    @discardableResult
    public func stream(_ userPrompt: String, _ onDelta: (String) -> Void) async throws -> Response {
        let config = providerConfig(provider)
        let model = try RequestBuilder.resolveModel(config, modelOverride)
        return try await Streamer.run(
            config: config, apiKey: apiKey, model: model, system: systemPrompt,
            msgs: userMsgs(userPrompt), options: options,
            http: http, baseURLOverride: baseURLOverride, onDelta: onDelta
        )
    }

    /// Submit a batch of single-turn prompts (ADR-064: batch is a text execution
    /// mode, parallel to stream) and return the live `BatchJob`. Fires the
    /// `batchSubmit` middleware op and threads the system prompt + caching into
    /// each per-item body.
    public func batch(_ prompts: String...) async throws -> BatchJob {
        let config = providerConfig(provider)
        guard options.proto.isEmpty else {
            throw LLMKitError.validation(field: "protocol", message: "batch supports only the default chat protocol")
        }
        let model = try RequestBuilder.resolveModel(config, modelOverride)

        let baseEvent = Event(op: .batchSubmit, provider: provider.rawValue, model: model)
        let start = Date()
        try Middleware.firePre(options.middleware, baseEvent)

        var postEvent = baseEvent
        do {
            let job = try await Batch.submit(
                config: config, apiKey: apiKey, http: http, baseURLOverride: baseURLOverride,
                model: model, system: systemPrompt, prompts: prompts,
                images: inputImages, files: inputFiles, options: options
            )
            postEvent.duration = Date().timeIntervalSince(start)
            Middleware.firePost(options.middleware, postEvent)
            return job
        } catch {
            postEvent.duration = Date().timeIntervalSince(start)
            postEvent.err = "\(error)"
            Middleware.firePost(options.middleware, postEvent)
            throw error
        }
    }

    /// Clone-on-chain helper: copy, mutate, return.
    private func with(_ mutate: (inout Text) -> Void) -> Text {
        var copy = self
        mutate(&copy)
        return copy
    }
}
