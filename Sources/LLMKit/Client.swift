import Foundation

/// The entry point to the SDK. An immutable value type; builders reached from it
/// clone on chain (ADR-066 SWIFT-004). Phase 0 exposes the `text` builder's
/// non-streaming `prompt` terminal for the OpenAI ChatCompletion slice.
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

    /// Convenience constructor for OpenAI.
    public static func openai(apiKey: String, session: URLSession = .shared) -> Client {
        Client(provider: .openai, apiKey: apiKey, session: session)
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
    var maxTokensOverride: Int?

    init(provider: ProviderName, apiKey: String, baseURLOverride: String?, http: HTTPClient) {
        self.provider = provider
        self.apiKey = apiKey
        self.baseURLOverride = baseURLOverride
        self.http = http
        self.modelOverride = nil
        self.systemPrompt = nil
        self.maxTokensOverride = nil
    }

    /// Select the model.
    public func model(_ model: String) -> Text {
        var copy = self
        copy.modelOverride = model
        return copy
    }

    /// Set the system instruction.
    public func system(_ system: String) -> Text {
        var copy = self
        copy.systemPrompt = system
        return copy
    }

    /// Set the maximum output tokens.
    public func maxTokens(_ maxTokens: Int) -> Text {
        var copy = self
        copy.maxTokensOverride = maxTokens
        return copy
    }

    /// Send a single-turn prompt and return the response.
    public func prompt(_ userPrompt: String) async throws -> Response {
        let config = providerConfig(provider)
        let model = try resolveModel(config)
        let maxTokens = maxTokensOverride ?? config.defaultMaxTokens

        let (body, headers) = try RequestBuilder.buildRequest(
            config: config,
            apiKey: apiKey,
            model: model,
            system: systemPrompt,
            userPrompt: userPrompt,
            maxTokens: maxTokens
        )
        let url = RequestBuilder.buildURL(config: config, baseURLOverride: baseURLOverride)

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
}
