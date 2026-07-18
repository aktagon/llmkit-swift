import Foundation

///
///
///
///
///
///
enum CachingRuntime {
    ///
    ///
    ///
    static func apply(
        _ body: inout JSONValue,
        provider: ProviderName,
        model: String,
        apiKey: String,
        options: PromptOptions,
        config: ProviderSpec,
        http: HTTPClient,
        baseURLOverride: String?
    ) async throws {
        guard options.caching else { return }
        guard let caching = cachingConfig(provider) else {
            throw LLMKitError.validation(field: "caching", message: "not supported by \(config.slug)")
        }
        switch caching.mode {
        case .automaticCaching:
            return
        case .explicitCaching:
            applyExplicit(&body, controlType: caching.controlType, config: config)
        case .resourceCaching:
            try await applyResource(
                &body, provider: provider, model: model, apiKey: apiKey,
                options: options, config: config, http: http, baseURLOverride: baseURLOverride
            )
        }
    }

    ///
    ///
    ///
    private static func applyExplicit(_ body: inout JSONValue, controlType: String, config: ProviderSpec) {
        guard case var .object(root) = body else { return }
        defer { body = .object(root) }

        func cachedTextBlock(_ text: String) -> JSONValue {
            .object([
                ("type", .string("text")),
                ("text", .string(text)),
                ("cache_control", .object([("type", .string(controlType))])),
            ])
        }

        switch config.systemPlacement {
        case "TopLevelField":
            guard case let .string(system)? = JSONObject.value(root, "system") else { return }
            JSONObject.set(&root, "system", .array([cachedTextBlock(system)]))
        case "MessageInArray":
            guard case var .array(messages)? = JSONObject.value(root, "messages") else { return }
            for index in messages.indices.reversed() {
                guard case var .object(message) = messages[index],
                      JSONObject.value(message, "role") == .string("system") else { continue }
                if case let .string(content)? = JSONObject.value(message, "content") {
                    JSONObject.set(&message, "content", .array([cachedTextBlock(content)]))
                    messages[index] = .object(message)
                }
                break
            }
            JSONObject.set(&root, "messages", .array(messages))
        default:
            break // SiblingObject — resource caching handles Google
        }
    }

    ///
    ///
    ///
    private static func applyResource(
        _ body: inout JSONValue,
        provider: ProviderName,
        model: String,
        apiKey: String,
        options: PromptOptions,
        config: ProviderSpec,
        http: HTTPClient,
        baseURLOverride: String?
    ) async throws {
        guard let lifecycle = cachingConfig(provider)?.lifecycle else {
            throw LLMKitError.unsupported("resource caching requires lifecycle config")
        }
        guard case var .object(root) = body else { return }
        guard let systemInstruction = JSONObject.value(root, "system_instruction") else { return }

        let ttl: String
        if let seconds = options.cacheTtl {
            ttl = "\(seconds)"
        } else {
            ttl = cachingConfig(provider)?.defaultTtl ?? ""
        }

        let base = baseURLOverride ?? config.baseURL
        let createURL = "\(base)\(lifecycle.createEndpoint)?\(config.authQueryParam)=\(urlencode(apiKey))"
        let createBody = JSONValue.object([
            ("model", .string("models/\(model)")),
            ("ttl", .string("\(ttl)s")),
            ("contents", .array([.object([
                ("role", .string("user")),
                ("parts", .array([.object([("text", .string("cache"))])])),
            ])])),
            ("systemInstruction", systemInstruction),
        ])

        let baseEvent = Event(op: .cacheCreate, provider: provider.rawValue, model: model)
        let start = Date()
        try Middleware.firePre(options.middleware, baseEvent)

        var postEvent = baseEvent
        let resourceID: String
        do {
            //
            //
            let headers = RequestBuilder.buildAuthHeaders(config: config, apiKey: apiKey)
            let (status, responseBody) = try await http.postJSON(url: createURL, body: createBody, headers: headers)
            guard (200..<300).contains(status) else {
                throw ResponseParser.parseError(config: config, statusCode: status, body: responseBody)
            }
            let parsed = try JSONValue.parse(String(decoding: responseBody, as: UTF8.self))
            let id = parsed.stringValue(at: lifecycle.responseIdPath)
            guard !id.isEmpty else { throw LLMKitError.unsupported("cache create: empty resource ID") }
            resourceID = id
        } catch {
            postEvent.duration = Date().timeIntervalSince(start)
            Middleware.setError(&postEvent, error)
            Middleware.firePost(options.middleware, postEvent)
            throw error
        }
        postEvent.duration = Date().timeIntervalSince(start)
        Middleware.firePost(options.middleware, postEvent)

        JSONObject.set(&root, lifecycle.referenceField, .string(resourceID))
        JSONObject.remove(&root, "system_instruction")
        body = .object(root)
    }
}
