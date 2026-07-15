import Foundation

///
///
///
///
public struct Client: Sendable {
    let provider: ProviderName
    let apiKey: String
    let baseURLOverride: String?
    let http: HTTPClient

    ///
    ///
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

    ///
    public static func openai(apiKey: String, session: URLSession = .shared) -> Client {
        Client(provider: .openai, apiKey: apiKey, session: session)
    }

    ///
    ///
    public func baseURL(_ url: String) -> Client {
        Client(provider: provider, apiKey: apiKey, baseURLOverride: url, http: http)
    }

    ///
    public var text: Text {
        Text(provider: provider, apiKey: apiKey, baseURLOverride: baseURLOverride, http: http)
    }
}

///
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

    ///
    public func model(_ model: String) -> Text { with { $0.modelOverride = model } }

    ///
    public func system(_ system: String) -> Text { with { $0.systemPrompt = system } }

    ///
    public func maxTokens(_ maxTokens: Int) -> Text { with { $0.options.maxTokens = maxTokens } }

    ///
    public func temperature(_ value: Double) -> Text { with { $0.options.temperature = value } }

    ///
    public func topP(_ value: Double) -> Text { with { $0.options.topP = value } }

    ///
    public func topK(_ value: Int) -> Text { with { $0.options.topK = value } }

    ///
    public func seed(_ value: Int) -> Text { with { $0.options.seed = Int64(value) } }

    ///
    public func frequencyPenalty(_ value: Double) -> Text { with { $0.options.frequencyPenalty = value } }

    ///
    public func presencePenalty(_ value: Double) -> Text { with { $0.options.presencePenalty = value } }

    ///
    public func thinkingBudget(_ value: Int) -> Text { with { $0.options.thinkingBudget = value } }

    ///
    public func reasoningEffort(_ value: String) -> Text { with { $0.options.reasoningEffort = value } }

    ///
    public func stopSequences(_ values: [String]) -> Text { with { $0.options.stopSequences = values } }

    ///
    public func safetySettings(_ values: [SafetySetting]) -> Text { with { $0.options.safetySettings = values } }

    ///
    public func schema(_ schema: String) -> Text { with { $0.options.schema = schema } }

    ///
    public func `protocol`(_ token: String) -> Text { with { $0.options.proto = token } }

    ///
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

    ///
    ///
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

    ///
    private func with(_ mutate: (inout Text) -> Void) -> Text {
        var copy = self
        mutate(&copy)
        return copy
    }
}
