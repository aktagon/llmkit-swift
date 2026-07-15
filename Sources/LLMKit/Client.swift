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

    ///
    public func agent() -> Agent {
        Agent(provider: provider, apiKey: apiKey, baseURLOverride: baseURLOverride, http: http)
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
        let model = try RequestBuilder.resolveModel(config, modelOverride)

        let (body, headers) = try RequestBuilder.buildBody(
            config: config,
            wireShape: wireShape,
            apiKey: apiKey,
            model: model,
            system: systemPrompt,
            msgs: [.text(role: "user", text: userPrompt)],
            tools: [],
            options: options
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
        return try ResponseParser.parse(config: config, body: data)
    }

    ///
    ///
    @discardableResult
    public func stream(_ userPrompt: String, _ onDelta: (String) -> Void) async throws -> Response {
        let config = providerConfig(provider)
        let model = try RequestBuilder.resolveModel(config, modelOverride)
        return try await Streamer.run(
            config: config, apiKey: apiKey, model: model, system: systemPrompt,
            msgs: [.text(role: "user", text: userPrompt)], options: options,
            http: http, baseURLOverride: baseURLOverride, onDelta: onDelta
        )
    }

    ///
    ///
    public func batch(_ prompts: String...) async throws -> BatchJob {
        let config = providerConfig(provider)
        guard options.proto.isEmpty else {
            throw LLMKitError.validation(field: "protocol", message: "batch supports only the default chat protocol")
        }
        let model = try RequestBuilder.resolveModel(config, modelOverride)
        return try await Batch.submit(
            config: config, apiKey: apiKey, http: http, baseURLOverride: baseURLOverride,
            model: model, prompts: prompts, options: options
        )
    }

    ///
    private func with(_ mutate: (inout Text) -> Void) -> Text {
        var copy = self
        mutate(&copy)
        return copy
    }
}
