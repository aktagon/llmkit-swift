import Foundation

///
///
///
///
///
///
///
///
///
///
///
///
///
///
///
///
///
///
///
///
public struct Video: Sendable {
    let provider: ProviderName
    let apiKey: String
    let baseURLOverride: String?
    let http: HTTPClient
    var modelOverride: String?
    ///
    var inputImages: [MediaRef] = []
    ///
    var outputURIValue: String = ""
    var rawOptIn: Bool = false
    var middleware: [MiddlewareFn] = []

    init(provider: ProviderName, apiKey: String, baseURLOverride: String?, http: HTTPClient) {
        self.provider = provider
        self.apiKey = apiKey
        self.baseURLOverride = baseURLOverride
        self.http = http
    }

    ///
    public func model(_ model: String) -> Video { with { $0.modelOverride = model } }

    ///
    ///
    ///
    public func image(_ mimeType: String, _ data: Data) -> Video {
        with { $0.inputImages.append(MediaRef(mimeType: mimeType, bytes: [UInt8](data))) }
    }

    ///
    ///
    public func outputURI(_ uri: String) -> Video { with { $0.outputURIValue = uri } }

    ///
    public func raw(_ enabled: Bool = true) -> Video { with { $0.rawOptIn = enabled } }

    ///
    public func addMiddleware(_ hook: @escaping MiddlewareFn) -> Video {
        with { $0.middleware.append(hook) }
    }

    ///
    ///
    ///
    ///
    ///
    public func submit(_ prompt: String) async throws -> VideoJob {
        guard let model = modelOverride, !model.isEmpty else {
            throw LLMKitError.validation(field: "model", message: "required for video generation")
        }
        let parts = try normalizeParts(prompt)

        let config = providerConfig(provider)
        guard let vgCfg = videoGenConfig(provider) else {
            throw LLMKitError.validation(field: "provider", message: "\(config.slug) does not support video generation")
        }
        guard let modelDef = vgCfg.models.first(where: { $0.modelId == model }) else {
            throw LLMKitError.validation(
                field: "model", message: "\(model) is not a known video-generation model for \(config.slug)"
            )
        }
        try validate(parts: parts, model: model, modelDef: modelDef, vgCfg: vgCfg)

        let baseEvent = Event(op: .videoGeneration, provider: provider.rawValue, model: model)
        let start = Date()
        try Middleware.firePre(middleware, baseEvent)

        var postEvent = baseEvent
        do {
            let id = try await dispatchSubmit(config: config, vgCfg: vgCfg, model: model, parts: parts)
            postEvent.duration = Date().timeIntervalSince(start)
            Middleware.firePost(middleware, postEvent)
            let handle = VideoHandle(id: id, provider: provider, raw: rawOptIn, model: model)
            return VideoJob(handle: handle, apiKey: apiKey, http: http, baseURLOverride: baseURLOverride)
        } catch {
            postEvent.duration = Date().timeIntervalSince(start)
            Middleware.setError(&postEvent, error)
            Middleware.firePost(middleware, postEvent)
            throw error
        }
    }

    ///
    private func with(_ mutate: (inout Video) -> Void) -> Video {
        var copy = self
        mutate(&copy)
        return copy
    }

    //

    ///
    private enum VideoPart {
        case text(String)
        case image(MediaRef)

        var isImage: Bool { if case .image = self { return true }; return false }
    }

    ///
    ///
    private func normalizeParts(_ prompt: String) throws -> [VideoPart] {
        if !inputImages.isEmpty {
            var parts = inputImages.map { VideoPart.image($0) }
            if !prompt.isEmpty { parts.append(.text(prompt)) }
            return parts
        }
        guard !prompt.isEmpty else {
            throw LLMKitError.validation(field: "prompt", message: "set either prompt or parts")
        }
        return [.text(prompt)]
    }

    private func joinPromptText(_ parts: [VideoPart]) -> String {
        parts.compactMap { if case let .text(s) = $0, !s.isEmpty { return s }; return nil }
            .joined(separator: "\n")
    }

    //

    ///
    ///
    ///
    private func validate(parts: [VideoPart], model: String, modelDef: VideoModelDef, vgCfg: VideoGenDef) throws {
        if parts.contains(where: \.isImage), !modelDef.supportsImageToVideo {
            throw LLMKitError.validation(
                field: "parts",
                message: "\(model) is a text-to-video-only model and does not accept image parts"
            )
        }
        if vgCfg.requiresOutputURI, outputURIValue.isEmpty {
            throw LLMKitError.validation(
                field: "output_uri",
                message: "\(providerConfig(provider).slug) requires a caller output S3 URI; set outputURI on the request"
            )
        }
    }

    //

    ///
    ///
    ///
    private func dispatchSubmit(
        config: ProviderSpec, vgCfg: VideoGenDef, model: String, parts: [VideoPart]
    ) async throws -> String {
        let base = videoBaseURL(config: config, vgCfg: vgCfg)
        var headers = RequestBuilder.buildAuthHeaders(config: config, apiKey: apiKey)
        headers.append(("content-type", "application/json"))

        let body: JSONValue
        switch vgCfg.wireShape {
        case "VideoQwen":
            //
            headers.append(("X-DashScope-Async", "enable"))
            body = .object([
                ("model", .string(model)),
                ("input", .object([("prompt", .string(joinPromptText(parts)))])),
            ])
        case "VideoPixVerse":
            //
            //
            //
            headers.append(("Ai-trace-id", Self.newTraceID()))
            body = .object([
                ("model", .string(model)),
                ("prompt", .string(joinPromptText(parts))),
                ("duration", .int(5)),
                ("quality", .string("540p")),
                ("aspect_ratio", .string("16:9")),
            ])
        case "VideoVeo", "VideoVertexVeo":
            //
            //
            body = .object([("instances", .array([.object([("prompt", .string(joinPromptText(parts)))])]))])
        case "VideoBedrock":
            //
            //
            body = .object([
                ("modelId", .string(model)),
                ("modelInput", .object([
                    ("taskType", .string("TEXT_VIDEO")),
                    ("textToVideoParams", .object([("text", .string(joinPromptText(parts)))])),
                ])),
                ("outputDataConfig", .object([
                    ("s3OutputDataConfig", .object([("s3Uri", .string(outputURIValue))])),
                ])),
            ])
        default:
            //
            //
            //
            var pairs: [(String, JSONValue)] = [
                ("model", .string(model)),
                ("prompt", .string(joinPromptText(parts))),
            ]
            if let seed = try seedImageURL(parts) {
                pairs.append(("image", .object([("url", .string(seed))])))
            }
            body = .object(pairs)
        }

        //
        //
        let url = appendQueryAuth(
            base + vgCfg.genEndpoint.replacingOccurrences(of: "{model}", with: model),
            config: config
        )

        let (status, data): (Int, Data)
        if config.authScheme == "SigV4" {
            let env = ProcessInfo.processInfo.environment
            let region = env[config.regionEnvVar] ?? ""
            let secretKey = env[config.secretKeyEnvVar] ?? ""
            let sessionToken = config.sessionTokenEnvVar.isEmpty ? "" : (env[config.sessionTokenEnvVar] ?? "")
            (status, data) = try await http.postJSONSigV4(
                url: url, body: body, accessKey: apiKey, secretKey: secretKey,
                sessionToken: sessionToken, region: region, service: config.serviceName
            )
        } else {
            (status, data) = try await http.postJSON(url: url, body: body, headers: headers)
        }
        guard (200..<300).contains(status) else {
            throw LLMKitError.api(provider: "video_submit", statusCode: status, message: String(decoding: data, as: UTF8.self))
        }
        let parsed = try JSONValue.parse(String(decoding: data, as: UTF8.self))
        let id = VideoWire.lookupHandleField(parsed, vgCfg.submitHandleField)
        guard !id.isEmpty else {
            throw LLMKitError.unsupported("video submit: empty handle field \"\(vgCfg.submitHandleField)\"")
        }
        return id
    }

    ///
    ///
    ///
    private func seedImageURL(_ parts: [VideoPart]) throws -> String? {
        var seed: MediaRef?
        for part in parts {
            if case let .image(media) = part {
                if seed != nil {
                    throw LLMKitError.validation(
                        field: "parts",
                        message: "image-to-video conditions on a single seed frame; pass one image part"
                    )
                }
                seed = media
            }
        }
        guard let media = seed else { return nil }
        let mime = media.mimeType.isEmpty ? "image/png" : media.mimeType
        return "data:\(mime);base64,\(Data(media.bytes).base64EncodedString())"
    }

    ///
    ///
    ///
    private func videoBaseURL(config: ProviderSpec, vgCfg: VideoGenDef) -> String {
        VideoWire.baseURL(config: config, vgCfg: vgCfg, override: baseURLOverride)
    }

    ///
    ///
    private func appendQueryAuth(_ url: String, config: ProviderSpec) -> String {
        VideoWire.appendQueryAuth(url, config: config, apiKey: apiKey)
    }

    ///
    ///
    ///
    static func newTraceID() -> String { UUID().uuidString.lowercased() }
}

///
///
public final class VideoJob: Sendable {
    ///
    public let handle: VideoHandle
    let apiKey: String
    let http: HTTPClient
    let baseURLOverride: String?
    ///
    let interval: TimeInterval
    let timeout: TimeInterval

    init(
        handle: VideoHandle, apiKey: String, http: HTTPClient, baseURLOverride: String?,
        interval: TimeInterval = 5, timeout: TimeInterval = 600
    ) {
        self.handle = handle
        self.apiKey = apiKey
        self.http = http
        self.baseURLOverride = baseURLOverride
        self.interval = interval
        self.timeout = timeout
    }

    ///
    ///
    func cadence(interval: TimeInterval, timeout: TimeInterval) -> VideoJob {
        VideoJob(
            handle: handle, apiKey: apiKey, http: http, baseURLOverride: baseURLOverride,
            interval: interval, timeout: timeout
        )
    }

    ///
    public func poll() async throws -> JobStatus<VideoResponse> {
        try await Job.pollOnce(try makeAdapter())
    }

    ///
    public func wait() async throws -> VideoResponse {
        var adapter = try makeAdapter()
        adapter.lc.pollInterval = interval
        adapter.lc.pollTimeout = timeout
        return try await Job.pollJob(adapter)
    }

    private func makeAdapter() throws -> VideoAdapter {
        try VideoAdapter(
            provider: handle.provider, apiKey: apiKey, http: http,
            baseURLOverride: baseURLOverride, id: handle.id, model: handle.model, raw: handle.raw
        )
    }
}
