import Foundation

///
///
///
enum RequestBuilder {
    ///
    static func buildRequest(
        config: ProviderSpec,
        apiKey: String,
        model: String,
        system: String?,
        userPrompt: String,
        maxTokens: Int
    ) throws -> (body: JSONValue, headers: [(String, String)]) {
        guard config.chatWireShape == "ChatOpenAI" else {
            throw LLMKitError.validation(
                field: "provider",
                message: "Phase 0 supports only the ChatOpenAI wire shape; got \(config.chatWireShape)"
            )
        }

        var body: [(String, JSONValue)] = []
        if config.modelInBody {
            body.append(("model", .string(model)))
        }
        body.append(("max_tokens", .int(Int64(maxTokens))))
        Transforms.applyMessageShape(
            body: &body,
            userPrompt: userPrompt,
            system: system,
            config: config
        )

        let headers = buildAuthHeaders(config: config, apiKey: apiKey)
        return (.object(body), headers)
    }

    ///
    static func buildAuthHeaders(config: ProviderSpec, apiKey: String) -> [(String, String)] {
        switch config.authScheme {
        case "BearerToken":
            return [(config.authHeader, "\(config.authPrefix) \(apiKey)")]
        case "HeaderApiKey":
            return [(config.authHeader, apiKey)]
        default:
            return []
        }
    }

    ///
    static func buildURL(config: ProviderSpec, baseURLOverride: String?) -> String {
        let base = baseURLOverride ?? config.baseURL
        return base + config.endpoint
    }
}
