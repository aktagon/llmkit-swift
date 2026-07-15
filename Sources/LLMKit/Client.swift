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

    /// Send a single-turn prompt and return the response.
    public func prompt(_ userPrompt: String) async throws -> Response {
        let config = providerConfig(provider)
        let (wireShape, endpoint) = try RequestBuilder.resolveChatProtocol(config: config, token: options.proto)
        let model = try resolveModel(config)

        let (body, headers) = try RequestBuilder.buildBody(
            config: config,
            wireShape: wireShape,
            apiKey: apiKey,
            model: model,
            system: systemPrompt,
            userPrompt: userPrompt,
            options: options
        )
        let url = RequestBuilder.buildURL(
            config: config, endpoint: endpoint, apiKey: apiKey, model: model, baseURLOverride: baseURLOverride
        )

        let (statusCode, data) = try await http.postJSON(url: url, body: body, headers: headers)
        guard (200..<300).contains(statusCode) else {
            throw ResponseParser.parseError(config: config, statusCode: statusCode, body: data)
        }
        return try ResponseParser.parse(config: config, body: data)
    }

    /// The chosen model, or the provider default; errors when neither exists
    /// (ADR-031 honest no-default contract).
    func resolveModel(_ config: ProviderSpec) throws -> String {
        if let modelOverride { return modelOverride }
        if config.defaultModel.isEmpty {
            throw LLMKitError.validation(
                field: "model",
                message: "no model chosen and \"\(config.slug)\" declares no default"
            )
        }
        return config.defaultModel
    }

    /// Clone-on-chain helper: copy, mutate, return.
    private func with(_ mutate: (inout Text) -> Void) -> Text {
        var copy = self
        mutate(&copy)
        return copy
    }
}
