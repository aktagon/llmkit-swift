import Foundation

/// Prompt-caching runtime — a port of Rust's `caching.rs`. Dispatches on the
/// generated `CachingDef.mode` (never on provider name): automatic caching is a
/// no-op (the provider caches transparently), explicit caching injects
/// `cache_control` onto the system prefix (Anthropic), and resource caching
/// creates a provider-side cached-content resource and references it (Google).
/// The generated `CachingMode` / `CachingDef` live in `Providers/Generated/`.
enum CachingRuntime {
    /// Apply caching to an already-built request body when the caller opted in
    /// (`options.caching`). No-op when caching is off; a loud validation error
    /// when the provider declares no caching config.
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

    /// Explicit caching (Anthropic): rewrite the system prefix into a single
    /// text block carrying `cache_control`. Placement is config-driven — the
    /// system lives at the top level (Anthropic) or as the last system message.
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

    /// Resource caching (Google): create a `/cachedContents` resource holding the
    /// system instruction, then reference it by name and drop the inline system.
    /// Fires the `cacheCreate` middleware op around the network hop.
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
        let createURL = "\(base)\(lifecycle.createEndpoint)?\(config.authQueryParam)=\(apiKey)"
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
            // ADR-052: Google resource caching authenticates via the URL query
            // param, so there is no auth header to collide with.
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
            postEvent.err = Middleware.errString(error)
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
