import Foundation

///
///
///
///
///
///
enum RequestBuilder {
    ///
    ///
    ///
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

    ///
    ///
    ///
    ///
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
        try validateOptions(config: config, options: options)

        var body: [(String, JSONValue)] = []
        var headers = buildAuthHeaders(config: config, apiKey: apiKey)

        if config.modelInBody {
            JSONObject.set(&body, "model", .string(model))
        }

        let maxTokens = options.maxTokens ?? config.defaultMaxTokens
        if let maxKey = resolveOptionKey(config.name, model, .maxTokens) {
            JSONObject.set(&body, maxKey, .int(Int64(maxTokens)))
        }

        //
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
        case "MessageInArray":
            break // system folds into the messages array (Transforms.applyMessageShape)
        default:
            throw LLMKitError.unsupported("chat request: unknown system placement \"\(config.systemPlacement)\"")
        }

        Transforms.applyMessageShape(
            body: &body, msgs: msgs, system: system, wireShape: wireShape, config: config
        )
        Transforms.applyToolDefs(&body, config, tools)

        //
        //
        //
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
            addStructuredOutput(&body, schema: schema, provider: config.name)
        }

        //
        //
        //
        //
        let beta = betaHeaders(config: config, options: options, msgs: msgs)
        if !beta.isEmpty {
            if let index = headers.firstIndex(where: { $0.0.caseInsensitiveCompare("anthropic-beta") == .orderedSame }) {
                headers[index].1 = appendBeta(headers[index].1, beta)
            } else {
                headers.append(("anthropic-beta", beta))
            }
        }

        //
        //
        if wireShape == "ChatResponsesOpenAI" {
            if let value = JSONObject.value(body, "max_tokens") {
                JSONObject.remove(&body, "max_tokens")
                JSONObject.set(&body, "max_output_tokens", value)
            }
        }

        return (.object(body), headers)
    }

    ///
    ///
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

    ///
    ///
    ///
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
            sessionToken: sessionToken, region: region, service: config.serviceName
        )
    }

    ///
    ///
    ///
    ///
    ///
    ///
    ///
    static func betaHeaders(config: ProviderSpec, options: PromptOptions, msgs: [Transforms.Msg]) -> String {
        var beta = ""
        if options.schema != nil, let def = structuredOutput(config.name), !def.betaHeader.isEmpty {
            beta = appendBeta(beta, def.betaHeader)
        }
        if Transforms.hasFileParts(msgs), let upload = fileUploadConfig(config.name), !upload.betaHeader.isEmpty {
            beta = appendBeta(beta, upload.betaHeader)
        }
        return beta
    }

    ///
    ///
    static func appendBeta(_ existing: String, _ addition: String) -> String {
        func tokens(_ s: String) -> [String] {
            s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        var values = tokens(existing)
        for token in tokens(addition) where !values.contains(token) {
            values.append(token)
        }
        return values.joined(separator: ",")
    }

    ///
    ///
    static func buildAuthHeaders(config: ProviderSpec, apiKey: String) -> [(String, String)] {
        var headers: [(String, String)] = []
        switch config.authScheme {
        case "BearerToken":
            headers.append((config.authHeader, "\(config.authPrefix) \(apiKey)"))
        case "HeaderAPIKey":
            headers.append((config.authHeader, apiKey))
        case "QueryParamKey", "SigV4":
            break // key rides in the URL query (buildURL) / the signature (send)
        default:
            break // unknown scheme contributes no header; the keyless request fails at the provider
        }
        if !config.requiredHeader.isEmpty {
            headers.append((config.requiredHeader, config.requiredHeaderValue))
        }
        return headers
    }

    ///
    ///
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
            .replacingOccurrences(of: "{apiKey}", with: urlencode(apiKey))
        if config.authScheme == "QueryParamKey" {
            let separator = resolved.contains("?") ? "&" : "?"
            resolved += "\(separator)\(config.authQueryParam)=\(urlencode(apiKey))"
        }
        return base + resolved
    }

    //

    ///
    ///
    ///
    ///
    ///
    static func validateOptions(config: ProviderSpec, options: PromptOptions) throws {
        let supported = supportedOptions(config.name)
        guard !supported.isEmpty else { return }
        func has(_ key: OptionKey) -> Bool {
            supported.contains { $0.key == key }
        }
        if options.topK != nil, !has(.topK) {
            throw LLMKitError.validation(field: "top_k", message: "not supported by \(config.slug)")
        }
        if options.seed != nil, !has(.seed) {
            throw LLMKitError.validation(field: "seed", message: "not supported by \(config.slug)")
        }
        if options.frequencyPenalty != nil, !has(.frequencyPenalty) {
            throw LLMKitError.validation(field: "frequency_penalty", message: "not supported by \(config.slug)")
        }
        if options.presencePenalty != nil, !has(.presencePenalty) {
            throw LLMKitError.validation(field: "presence_penalty", message: "not supported by \(config.slug)")
        }
        if options.thinkingBudget != nil, !has(.thinkingBudget) {
            throw LLMKitError.validation(field: "thinking_budget", message: "not supported by \(config.slug)")
        }
        if let effort = options.reasoningEffort {
            if !has(.reasoningEffort) {
                throw LLMKitError.validation(field: "reasoning_effort", message: "not supported by \(config.slug)")
            }
            //
            //
            if let override = optionOverrides(config.name).first(
                where: { $0.key == .reasoningEffort && !$0.allowedValues.isEmpty }),
                !override.allowedValues.contains(effort) {
                throw LLMKitError.validation(
                    field: "reasoning_effort",
                    message: "invalid value \"\(effort)\", must be one of: \(override.allowedValues.joined(separator: ","))"
                )
            }
        }
    }

    ///
    ///
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

        //
        //
        //
        if let override = optionOverrides(config.name).first(where: { $0.key == key && !$0.extraFieldsJSON.isEmpty }),
           case let .object(extras)? = try? JSONValue.parse(override.extraFieldsJSON) {
            JSONObject.mergeIntoParent(&body, jsonKey, extras)
        }
        //
        //
        if let override = optionOverrides(config.name).first(where: { $0.key == key && !$0.rootExtraFieldsJSON.isEmpty }),
           case let .object(extras)? = try? JSONValue.parse(override.rootExtraFieldsJSON) {
            JSONObject.deepMerge(&rootExtras, extras)
        }
    }

    ///
    ///
    ///
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

    //

    private static func addStructuredOutput(
        _ body: inout [(String, JSONValue)],
        schema: String,
        provider: ProviderName
    ) {
        guard let def = structuredOutput(provider) else { return }
        guard var parsed = try? JSONValue.parse(schema) else { return }

        if def.enforceStrict { setAdditionalPropertiesFalse(&parsed) }
        if def.removeAdditionalProps { removeAdditionalProperties(&parsed) }
        //
        //

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

    ///
    ///
    ///
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

    ///
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
