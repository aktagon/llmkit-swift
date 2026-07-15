import Foundation

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

    ///
    public static func openai(apiKey: String, session: URLSession = .shared) -> Client {
        Client(provider: .openai, apiKey: apiKey, session: session)
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

    ///
    public func model(_ model: String) -> Text {
        var copy = self
        copy.modelOverride = model
        return copy
    }

    ///
    public func system(_ system: String) -> Text {
        var copy = self
        copy.systemPrompt = system
        return copy
    }

    ///
    public func maxTokens(_ maxTokens: Int) -> Text {
        var copy = self
        copy.maxTokensOverride = maxTokens
        return copy
    }

    ///
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
}
