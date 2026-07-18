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
    let defaultMiddleware: [MiddlewareFn]

    ///
    ///
    public init(provider: ProviderName, apiKey: String, session: URLSession = .shared) {
        self.provider = provider
        self.apiKey = apiKey
        self.baseURLOverride = nil
        self.http = HTTPClient(session: session)
        self.defaultMiddleware = []
    }

    private init(
        provider: ProviderName, apiKey: String, baseURLOverride: String?,
        http: HTTPClient, defaultMiddleware: [MiddlewareFn]
    ) {
        self.provider = provider
        self.apiKey = apiKey
        self.baseURLOverride = baseURLOverride
        self.http = http
        self.defaultMiddleware = defaultMiddleware
    }

    ///
    public static func openai(apiKey: String, session: URLSession = .shared) -> Client {
        Client(provider: .openai, apiKey: apiKey, session: session)
    }

    ///
    ///
    public func baseURL(_ url: String) -> Client {
        Client(
            provider: provider, apiKey: apiKey, baseURLOverride: url,
            http: http, defaultMiddleware: defaultMiddleware
        )
    }

    ///
    ///
    ///
    ///
    ///
    ///
    ///
    public func addHeader(_ name: String, _ value: String) -> Client {
        var next = http.customHeaders
        if let index = next.firstIndex(where: { $0.0.caseInsensitiveCompare(name) == .orderedSame }) {
            next[index] = (name, value)
        } else {
            next.append((name, value))
        }
        return Client(
            provider: provider, apiKey: apiKey, baseURLOverride: baseURLOverride,
            http: HTTPClient(session: http.session, customHeaders: next),
            defaultMiddleware: defaultMiddleware
        )
    }

    ///
    ///
    ///
    ///
    ///
    public func addTelemetry(_ telemetry: Telemetry) -> Client {
        Client(
            provider: provider, apiKey: apiKey, baseURLOverride: baseURLOverride,
            http: http, defaultMiddleware: defaultMiddleware + [TelemetryRuntime.makeMiddleware(telemetry)]
        )
    }

    ///
    ///
    ///
    ///
    func addMiddleware(_ hook: @escaping MiddlewareFn) -> Client {
        Client(
            provider: provider, apiKey: apiKey, baseURLOverride: baseURLOverride,
            http: http, defaultMiddleware: defaultMiddleware + [hook]
        )
    }

    ///
    public var text: Text {
        var builder = Text(provider: provider, apiKey: apiKey, baseURLOverride: baseURLOverride, http: http)
        for hook in defaultMiddleware { builder = builder.addMiddleware(hook) }
        return builder
    }

    ///
    public var image: Image {
        var builder = Image(provider: provider, apiKey: apiKey, baseURLOverride: baseURLOverride, http: http)
        for hook in defaultMiddleware { builder = builder.addMiddleware(hook) }
        return builder
    }

    ///
    public var speech: Speech {
        Speech(provider: provider, apiKey: apiKey, baseURLOverride: baseURLOverride, http: http)
    }

    ///
    public var music: Music {
        var builder = Music(provider: provider, apiKey: apiKey, baseURLOverride: baseURLOverride, http: http)
        for hook in defaultMiddleware { builder = builder.addMiddleware(hook) }
        return builder
    }

    ///
    ///
    public var video: Video {
        var builder = Video(provider: provider, apiKey: apiKey, baseURLOverride: baseURLOverride, http: http)
        for hook in defaultMiddleware { builder = builder.addMiddleware(hook) }
        return builder
    }

    ///
    ///
    ///
    ///
    ///
    public var transcription: Transcription {
        Transcription(provider: provider, apiKey: apiKey, baseURLOverride: baseURLOverride, http: http)
    }

    ///
    ///
    ///
    public var models: Models {
        Models(client: self)
    }

    ///
    ///
    ///
    public var providers: Providers {
        Providers(client: self)
    }

    ///
    ///
    ///
    public func upload() -> Upload {
        var builder = Upload(provider: provider, apiKey: apiKey, baseURLOverride: baseURLOverride, http: http)
        for hook in defaultMiddleware { builder = builder.addMiddleware(hook) }
        return builder
    }

    ///
    public func agent() -> Agent {
        let agent = Agent(provider: provider, apiKey: apiKey, baseURLOverride: baseURLOverride, http: http)
        for hook in defaultMiddleware { agent.addMiddleware(hook) }
        return agent
    }

    ///
    ///
    ///
    ///
    ///
    ///
    ///
    ///
    public func supports(_ capability: Capability) -> Bool {
        switch capability {
        case .caching: return cachingConfig(provider) != nil
        case .batching: return batchConfig(provider) != nil
        case .fileUpload: return fileUploadConfig(provider) != nil
        case .imageGeneration: return imageGenConfig(provider) != nil
        default: return true
        }
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
    var inputImages: [InputImage] = []
    var inputFiles: [FileRef] = []

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
    public func caching() -> Text { with { $0.options.caching = true } }

    ///
    public func cacheTtl(_ seconds: Int) -> Text { with { $0.options.cacheTtl = seconds } }

    ///
    public func addMiddleware(_ hook: @escaping MiddlewareFn) -> Text {
        with { $0.options.middleware.append(hook) }
    }

    ///
    ///
    ///
    public func image(_ mimeType: String, _ data: Data) -> Text {
        with {
            $0.inputImages.append(InputImage(
                url: "data:\(mimeType);base64,\(data.base64EncodedString())",
                mimeType: mimeType, detail: ""
            ))
        }
    }

    ///
    ///
    ///
    public func file(_ id: String) -> Text {
        with { $0.inputFiles.append(FileRef(id: id, uri: "", mimeType: "")) }
    }

    ///
    ///
    ///
    private func userMsgs(_ prompt: String) -> [Transforms.Msg] {
        if inputImages.isEmpty, inputFiles.isEmpty {
            return [.text(role: "user", text: prompt)]
        }
        return [.media(role: "user", text: prompt, images: inputImages, files: inputFiles)]
    }

    ///
    ///
    ///
    public func prompt(_ userPrompt: String) async throws -> Response {
        let config = providerConfig(provider)
        let (wireShape, endpoint) = try RequestBuilder.resolveChatProtocol(config: config, token: options.proto)
        let model = try RequestBuilder.resolveModel(config, modelOverride)

        let baseEvent = Event(op: .llmRequest, provider: provider.rawValue, model: model)
        let start = Date()
        try Middleware.firePre(options.middleware, baseEvent)

        var postEvent = baseEvent
        do {
            var (body, headers) = try RequestBuilder.buildBody(
                config: config,
                wireShape: wireShape,
                apiKey: apiKey,
                model: model,
                system: systemPrompt,
                msgs: userMsgs(userPrompt),
                tools: [],
                options: options
            )
            try await CachingRuntime.apply(
                &body, provider: provider, model: model, apiKey: apiKey,
                options: options, config: config, http: http, baseURLOverride: baseURLOverride
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
            let response = try ResponseParser.parse(config: config, body: data)
            postEvent.duration = Date().timeIntervalSince(start)
            postEvent.usage = response.usage
            Middleware.firePost(options.middleware, postEvent)
            return response
        } catch {
            postEvent.duration = Date().timeIntervalSince(start)
            Middleware.setError(&postEvent, error)
            Middleware.firePost(options.middleware, postEvent)
            throw error
        }
    }

    ///
    ///
    @discardableResult
    public func stream(_ userPrompt: String, _ onDelta: @Sendable (String) -> Void) async throws -> Response {
        let config = providerConfig(provider)
        guard options.proto.isEmpty else {
            throw LLMKitError.validation(field: "protocol", message: "stream supports only the default chat protocol")
        }
        let model = try RequestBuilder.resolveModel(config, modelOverride)
        return try await Streamer.run(
            config: config, apiKey: apiKey, model: model, system: systemPrompt,
            msgs: userMsgs(userPrompt), options: options,
            http: http, baseURLOverride: baseURLOverride, onDelta: onDelta
        )
    }

    ///
    ///
    ///
    ///
    public func batch(_ prompts: String...) async throws -> BatchJob {
        let config = providerConfig(provider)
        guard options.proto.isEmpty else {
            throw LLMKitError.validation(field: "protocol", message: "batch supports only the default chat protocol")
        }
        let model = try RequestBuilder.resolveModel(config, modelOverride)

        let baseEvent = Event(op: .batchSubmit, provider: provider.rawValue, model: model)
        let start = Date()
        try Middleware.firePre(options.middleware, baseEvent)

        var postEvent = baseEvent
        do {
            let job = try await Batch.submit(
                config: config, apiKey: apiKey, http: http, baseURLOverride: baseURLOverride,
                model: model, system: systemPrompt, prompts: prompts,
                images: inputImages, files: inputFiles, options: options
            )
            postEvent.duration = Date().timeIntervalSince(start)
            Middleware.firePost(options.middleware, postEvent)
            return job
        } catch {
            postEvent.duration = Date().timeIntervalSince(start)
            Middleware.setError(&postEvent, error)
            Middleware.firePost(options.middleware, postEvent)
            throw error
        }
    }

    ///
    private func with(_ mutate: (inout Text) -> Void) -> Text {
        var copy = self
        mutate(&copy)
        return copy
    }
}
