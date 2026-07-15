import Foundation

/// Builds the provider-specific chat request body, headers, and URL from the
/// generated `ProviderSpec` + option tables. Selected by config facts
/// (`chatWireShape`, `systemPlacement`, `authScheme`, `wrapsOptionsIn`), never
/// by provider name — a file-by-file port of Rust's `request.rs::build_request`
/// covering the Phase 2 ChatCompletion surface (options, structured output,
/// the Responses protocol; media Parts / tools / SigV4 land in later phases).
enum RequestBuilder {
    /// Resolve a chat-protocol opt-in token (ADR-055) to the effective
    /// `(wireShape, endpoint)`. An empty token keeps the default; an unknown or
    /// unsupported token is a loud validation error before any body is built.
    static func resolveChatProtocol(
        config: ProviderSpec,
        token: String
    ) throws -> (wireShape: String, endpoint: String) {
        if token.isEmpty {
            return (config.chatWireShape, config.endpoint)
        }
        guard let want = protocolWireShape(token) else {
            throw LLMKitError.validation(field: "protocol", message: "unknown protocol: \(token)")
        }
        for proto in config.chatProtocols where proto.wireShape == want {
            return (proto.wireShape, proto.endpoint)
        }
        throw LLMKitError.validation(
            field: "protocol",
            message: "provider \(config.slug) does not support protocol \"\(token)\""
        )
    }

    private static func protocolWireShape(_ token: String) -> String? {
        token == "responses" ? "ChatResponsesOpenAI" : nil
    }

    /// Construct the request body + headers for a chat request. `msgs` is the
    /// internal message list (a single user turn on the Text path, the full
    /// history on the Agent path); `tools` serializes tool definitions when the
    /// caller registered any. Mirror of Rust's `build_request`.
    static func buildBody(
        config: ProviderSpec,
        wireShape: String,
        apiKey: String,
        model: String,
        system: String?,
        msgs: [Transforms.Msg],
        tools: [Tool],
        options: PromptOptions
    ) throws -> (body: JSONValue, headers: [(String, String)]) {
        var body: [(String, JSONValue)] = []
        var headers = buildAuthHeaders(config: config, apiKey: apiKey)

        if config.modelInBody {
            JSONObject.set(&body, "model", .string(model))
        }

        let maxTokens = options.maxTokens ?? config.defaultMaxTokens
        if let maxKey = resolveOptionKey(config.name, model, .maxTokens) {
            JSONObject.set(&body, maxKey, .int(Int64(maxTokens)))
        }

        // System placement (the message-array case is handled inside the shape).
        switch config.systemPlacement {
        case "TopLevelField":
            if let system {
                if wireShape == "ChatBedrock" {
                    JSONObject.set(&body, "system", .array([.object([("text", .string(system))])]))
                } else {
                    JSONObject.set(&body, "system", .string(system))
                }
            }
        case "SiblingObject":
            if let system {
                JSONObject.set(
                    &body, "system_instruction",
                    .object([("parts", .array([.object([("text", .string(system))])]))])
                )
            }
        default:
            break // MessageInArray
        }

        Transforms.applyMessageShape(
            body: &body, msgs: msgs, system: system, wireShape: wireShape, config: config
        )
        Transforms.applyToolDefs(&body, config, tools)

        // Options. When the provider wraps options (Google's generationConfig),
        // the generation params + max-token key nest inside the wrapper; root
        // extras (ADR-029) always deep-merge at the true body root.
        if !config.wrapsOptionsIn.isEmpty {
            var wrapped: [(String, JSONValue)] = []
            let rootExtras = addOptions(&wrapped, config, model, options)
            if let maxKey = resolveOptionKey(config.name, model, .maxTokens) {
                JSONObject.insertNested(&wrapped, maxKey, .int(Int64(maxTokens)))
                JSONObject.remove(&body, maxKey)
            }
            if !wrapped.isEmpty {
                JSONObject.set(&body, config.wrapsOptionsIn, .object(wrapped))
            }
            JSONObject.deepMerge(&body, rootExtras)
        } else {
            let rootExtras = addOptions(&body, config, model, options)
            JSONObject.deepMerge(&body, rootExtras)
        }

        if !config.safetySettingsWirePath.isEmpty, !options.safetySettings.isEmpty {
            let settings = options.safetySettings.map { setting in
                JSONValue.object([
                    ("category", .string(setting.category)),
                    ("threshold", .string(setting.threshold)),
                ])
            }
            JSONObject.set(&body, config.safetySettingsWirePath, .array(settings))
        }

        if let schema = options.schema {
            addStructuredOutput(&body, &headers, schema: schema, provider: config.name)
        }

        // ADR-055 Responses body fixup: the output-token cap is named
        // `max_output_tokens` (not `max_tokens`) on the Responses envelope.
        if wireShape == "ChatResponsesOpenAI" {
            if let value = JSONObject.value(body, "max_tokens") {
                JSONObject.remove(&body, "max_tokens")
                JSONObject.set(&body, "max_output_tokens", value)
            }
        }

        return (.object(body), headers)
    }

    /// The chosen model, or the provider default; errors when neither exists
    /// (ADR-031 honest no-default contract).
    static func resolveModel(_ config: ProviderSpec, _ override: String?) throws -> String {
        if let override { return override }
        if config.defaultModel.isEmpty {
            throw LLMKitError.validation(
                field: "model",
                message: "no model chosen and \"\(config.slug)\" declares no default"
            )
        }
        return config.defaultModel
    }

    /// Send a chat request, dispatching on the auth scheme: a SigV4 provider
    /// (Bedrock) signs the exact bytes and reads its credentials from the
    /// environment (ADR-052); every other provider posts with the auth headers.
    static func send(
        config: ProviderSpec,
        url: String,
        body: JSONValue,
        headers: [(String, String)],
        apiKey: String,
        http: HTTPClient
    ) async throws -> (statusCode: Int, data: Data) {
        guard config.authScheme == "SigV4" else {
            return try await http.postJSON(url: url, body: body, headers: headers)
        }
        let env = ProcessInfo.processInfo.environment
        guard let region = env[config.regionEnvVar] else {
            throw LLMKitError.validation(field: "provider", message: "missing env var \(config.regionEnvVar)")
        }
        guard let secretKey = env[config.secretKeyEnvVar] else {
            throw LLMKitError.validation(field: "provider", message: "missing env var \(config.secretKeyEnvVar)")
        }
        let sessionToken = config.sessionTokenEnvVar.isEmpty ? "" : (env[config.sessionTokenEnvVar] ?? "")
        return try await http.postJSONSigV4(
            url: url, body: body, accessKey: apiKey, secretKey: secretKey,
            sessionToken: sessionToken, region: region, service: config.serviceName, callerHeaders: []
        )
    }

    /// Provider auth + required headers, dispatched on the generated
    /// `authScheme` fact (QueryParamKey / SigV4 contribute no header here).
    static func buildAuthHeaders(config: ProviderSpec, apiKey: String) -> [(String, String)] {
        var headers: [(String, String)] = []
        switch config.authScheme {
        case "BearerToken":
            headers.append((config.authHeader, "\(config.authPrefix) \(apiKey)"))
        case "HeaderAPIKey":
            headers.append((config.authHeader, apiKey))
        default:
            break // QueryParamKey / SigV4
        }
        if !config.requiredHeader.isEmpty {
            headers.append((config.requiredHeader, config.requiredHeaderValue))
        }
        return headers
    }

    /// The request URL: base (with optional override) + endpoint, resolving
    /// `{region}`/`{model}`/`{apiKey}` placeholders and the QueryParamKey `?key=`.
    static func buildURL(
        config: ProviderSpec,
        endpoint: String,
        apiKey: String,
        model: String,
        baseURLOverride: String?
    ) -> String {
        var base = baseURLOverride ?? config.baseURL
        if !config.regionEnvVar.isEmpty, let region = ProcessInfo.processInfo.environment[config.regionEnvVar] {
            base = base.replacingOccurrences(of: "{region}", with: region)
        }
        var resolved = endpoint
            .replacingOccurrences(of: "{model}", with: model)
            .replacingOccurrences(of: "{apiKey}", with: apiKey)
        if config.authScheme == "QueryParamKey" {
            let separator = resolved.contains("?") ? "&" : "?"
            resolved += "\(separator)\(config.authQueryParam)=\(apiKey)"
        }
        return base + resolved
    }

    // MARK: - Options

    /// Applies generation parameters to `body` and returns the accumulated root
    /// extras (ADR-029 THK-003) for the caller to deep-merge at the body root.
    private static func addOptions(
        _ body: inout [(String, JSONValue)],
        _ config: ProviderSpec,
        _ model: String,
        _ options: PromptOptions
    ) -> [(String, JSONValue)] {
        var rootExtras: [(String, JSONValue)] = []
        maybeInsert(&body, config, model, .temperature, options.temperature.map { .double($0) }, &rootExtras)
        maybeInsert(&body, config, model, .topP, options.topP.map { .double($0) }, &rootExtras)
        maybeInsert(&body, config, model, .topK, options.topK.map { .int(Int64($0)) }, &rootExtras)
        maybeInsert(&body, config, model, .seed, options.seed.map { .int($0) }, &rootExtras)
        maybeInsert(&body, config, model, .frequencyPenalty, options.frequencyPenalty.map { .double($0) }, &rootExtras)
        maybeInsert(&body, config, model, .presencePenalty, options.presencePenalty.map { .double($0) }, &rootExtras)
        maybeInsert(&body, config, model, .thinkingBudget, options.thinkingBudget.map { .int(Int64($0)) }, &rootExtras)
        maybeInsert(&body, config, model, .reasoningEffort, options.reasoningEffort.map { .string($0) }, &rootExtras)
        if !options.stopSequences.isEmpty {
            maybeInsert(
                &body, config, model, .stopSequences,
                .array(options.stopSequences.map { .string($0) }), &rootExtras
            )
        }
        return rootExtras
    }

    private static func maybeInsert(
        _ body: inout [(String, JSONValue)],
        _ config: ProviderSpec,
        _ model: String,
        _ key: OptionKey,
        _ value: JSONValue?,
        _ rootExtras: inout [(String, JSONValue)]
    ) {
        guard let value else { return }
        guard let jsonKey = resolveOptionKey(config.name, model, key) else { return }
        JSONObject.insertNested(&body, jsonKey, value)

        // Static sibling fields from the option override (e.g. Anthropic's
        // {"type":"enabled"} alongside thinking.budget_tokens) merge into the
        // leaf's parent object.
        if let override = optionOverrides(config.name).first(where: { $0.key == key && !$0.extraFieldsJSON.isEmpty }),
           case let .object(extras)? = try? JSONValue.parse(override.extraFieldsJSON) {
            JSONObject.mergeIntoParent(&body, jsonKey, extras)
        }
        // Root extras (ADR-029): static fields the option implies at the body
        // ROOT (e.g. {"thinking":{"type":"adaptive"}} alongside output_config.effort).
        if let override = optionOverrides(config.name).first(where: { $0.key == key && !$0.rootExtraFieldsJSON.isEmpty }),
           case let .object(extras)? = try? JSONValue.parse(override.rootExtraFieldsJSON) {
            JSONObject.deepMerge(&rootExtras, extras)
        }
    }

    /// Wire (JSON) key for `key` on `(provider, model)`. Per-model overrides
    /// (ADR-024) outrank the provider default: an exact id match wins outright,
    /// else the longest-prefix glob wins, else the provider's supported-options key.
    static func resolveOptionKey(_ provider: ProviderName, _ model: String, _ key: OptionKey) -> String? {
        var bestKey: String?
        var bestLen = -1
        for override in modelOptionOverrides(provider) where override.key == key {
            if override.matcherKind == "id" {
                if override.matcherValue == model { return override.jsonKey }
            } else {
                let prefix = override.matcherValue.hasSuffix("*")
                    ? String(override.matcherValue.dropLast())
                    : override.matcherValue
                if model.hasPrefix(prefix), prefix.count > bestLen {
                    bestKey = override.jsonKey
                    bestLen = prefix.count
                }
            }
        }
        if bestLen >= 0 { return bestKey }
        return supportedOptions(provider).first(where: { $0.key == key })?.jsonKey
    }

    // MARK: - Structured output

    private static func addStructuredOutput(
        _ body: inout [(String, JSONValue)],
        _ headers: inout [(String, String)],
        schema: String,
        provider: ProviderName
    ) {
        guard let def = structuredOutput(provider) else { return }
        guard var parsed = try? JSONValue.parse(schema) else { return }

        if def.enforceStrict { setAdditionalPropertiesFalse(&parsed) }
        if def.removeAdditionalProps { removeAdditionalProperties(&parsed) }
        if !def.betaHeader.isEmpty { headers.append(("anthropic-beta", def.betaHeader)) }

        if def.schemaPlacement == "SiblingOfFormat" {
            JSONObject.insertNested(&body, def.formatField, .string(def.formatType))
            JSONObject.insertNested(&body, def.schemaPath, parsed)
            return
        }

        let pathParts = def.schemaPath.split(separator: ".").map(String.init)
        let formatObject: JSONValue
        if pathParts.count == 1 {
            formatObject = .object([
                ("type", .string(def.formatType)),
                (pathParts[0], parsed),
            ])
        } else {
            formatObject = .object([
                ("type", .string(def.formatType)),
                (pathParts[0], .object([
                    ("name", .string("response")),
                    (pathParts[1], parsed),
                    ("strict", .bool(def.enforceStrict)),
                ])),
            ])
        }
        JSONObject.insertNested(&body, def.formatField, formatObject)
    }

    /// EnforceStrict normalization: set `additionalProperties:false` on every
    /// object node and auto-fill `required` with all property keys when absent
    /// (recursing through `properties` and `items`).
    private static func setAdditionalPropertiesFalse(_ schema: inout JSONValue) {
        guard case var .object(pairs) = schema else { return }
        if JSONObject.value(pairs, "type") == .string("object") {
            JSONObject.set(&pairs, "additionalProperties", .bool(false))
            if !pairs.contains(where: { $0.0 == "required" }),
               case let .object(props)? = JSONObject.value(pairs, "properties") {
                JSONObject.set(&pairs, "required", .array(props.map { .string($0.0) }))
            }
            if let index = pairs.firstIndex(where: { $0.0 == "properties" }),
               case var .object(props) = pairs[index].1 {
                for i in props.indices { setAdditionalPropertiesFalse(&props[i].1) }
                pairs[index].1 = .object(props)
            }
        }
        if let index = pairs.firstIndex(where: { $0.0 == "items" }) {
            setAdditionalPropertiesFalse(&pairs[index].1)
        }
        schema = .object(pairs)
    }

    /// Google normalization: strip `additionalProperties` at every node.
    private static func removeAdditionalProperties(_ schema: inout JSONValue) {
        guard case var .object(pairs) = schema else { return }
        JSONObject.remove(&pairs, "additionalProperties")
        if let index = pairs.firstIndex(where: { $0.0 == "properties" }),
           case var .object(props) = pairs[index].1 {
            for i in props.indices { removeAdditionalProperties(&props[i].1) }
            pairs[index].1 = .object(props)
        }
        if let index = pairs.firstIndex(where: { $0.0 == "items" }) {
            removeAdditionalProperties(&pairs[index].1)
        }
        schema = .object(pairs)
    }
}
