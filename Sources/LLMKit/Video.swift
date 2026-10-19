import Foundation

/// Video-generation runtime (ADR-034) — a port of Rust's `video.rs` onto the
/// shared Job engine (ADR-062). Asynchronous: `client.video.<config>.submit(prompt)`
/// POSTs the provider submit body and returns a live `VideoJob` immediately; the
/// job polls the lifecycle to completion (`wait`) or one round-trip at a time
/// (`poll`).
///
/// Dispatch branches on the generated `videoGenConfig(provider).wireShape` fact —
/// never on the provider name. Eleven wire shapes ship: the shared `{model,
/// prompt}` arm (Grok / Zhipu / Vidu / Together / MiniMax), Grok's image-to-video
/// seed frame inlined as a data URL at `image.url` (BUG-010), the nested Qwen
/// `{model, input:{prompt}}` (with the `X-DashScope-Async: enable` header),
/// PixVerse's five-field body (+ a per-request `Ai-trace-id` header), the
/// model-in-path Veo / Vertex `{instances:[{prompt}]}`, and Bedrock Nova Reel's
/// SigV4-signed `{modelId, modelInput, outputDataConfig}` (VID-005).
///
/// The generated `VideoHandle` value carries only identity (id + provider + raw +
/// model). Swift maps `Provider` to `ProviderName`, so the credential-bearing,
/// transport-holding *live* handle is a handwritten wrapper (`VideoJob`) around
/// it (mirror of `BatchJob`). `VideoJob.handle` is the persistable value for
/// cross-process resume (ADR-014).
public struct Video: Sendable {
    let provider: ProviderName
    let apiKey: String
    let baseURLOverride: String?
    let http: HTTPClient
    var modelOverride: String?
    /// Accumulated seed frames for the image-to-video path (caller order).
    var inputImages: [MediaRef] = []
    /// Ordered text parts accumulated by `.text(...)`. `submit(prompt)` appends
    /// its own argument after these, so the request reads in caller order.
    var textParts: [String] = []
    /// The final frame the video ends on (BUG-089).
    var lastFrameImage: MediaRef?
    /// Asset reference images, in caller order (BUG-089).
    var referenceImages: [MediaRef] = []
    /// Video length in whole seconds; 0 means unset (HANDOFF-097).
    var durationSeconds: Int = 0
    /// Output aspect ratio, such as "16:9"; empty means unset (HANDOFF-097).
    var aspectRatioValue: String = ""
    /// Output resolution, such as "720p"; empty means unset (HANDOFF-097).
    var resolutionValue: String = ""
    /// Caller S3 destination URI for output-uri delivery (Bedrock Nova Reel).
    var outputURIValue: String = ""
    var rawOptIn: Bool = false
    var middleware: [MiddlewareFn] = []

    init(provider: ProviderName, apiKey: String, baseURLOverride: String?, http: HTTPClient) {
        self.provider = provider
        self.apiKey = apiKey
        self.baseURLOverride = baseURLOverride
        self.http = http
    }

    /// Select the video-generation model (required).
    public func model(_ model: String) -> Video { with { $0.modelOverride = model } }

    /// Attach a seed frame for the image-to-video path (BUG-010). The bytes are
    /// base64-encoded into a data URL at wire time. Accepted only by models whose
    /// `VideoModelDef` sets `supportsImageToVideo`.
    public func image(_ mimeType: String, _ data: Data) -> Video {
        with { $0.inputImages.append(MediaRef(mimeType: mimeType, bytes: [UInt8](data))) }
    }

    /// Set the final frame the video ends on. Send it with a first frame
    /// (`image`) on a model that takes a last frame; otherwise it is rejected
    /// before send (BUG-089).
    public func lastFrame(_ mimeType: String, _ data: Data) -> Video {
        with { $0.lastFrameImage = MediaRef(mimeType: mimeType, bytes: [UInt8](data)) }
    }

    /// Append an asset reference image, such as a person, character or product
    /// the video keeps. Add at most 3, without `image` or `lastFrame` (BUG-089).
    public func addReferenceImage(_ mimeType: String, _ data: Data) -> Video {
        with { $0.referenceImages.append(MediaRef(mimeType: mimeType, bytes: [UInt8](data))) }
    }

    /// Set the video length in whole seconds. Only OpenRouter sends it; a
    /// length above the model's maximum is rejected before send (HANDOFF-097).
    public func duration(_ seconds: Int) -> Video { with { $0.durationSeconds = seconds } }

    /// Set the output aspect ratio, such as "16:9". Only OpenRouter sends it; a
    /// ratio the model does not list is rejected before send (HANDOFF-097).
    public func aspectRatio(_ ratio: String) -> Video { with { $0.aspectRatioValue = ratio } }

    /// Set the output resolution, such as "720p". Only OpenRouter sends it; a
    /// resolution the model does not list is rejected before send (HANDOFF-097).
    public func resolution(_ resolution: String) -> Video { with { $0.resolutionValue = resolution } }

    /// Set the caller-supplied destination S3 URI (required by output-uri
    /// delivery providers, e.g. Bedrock Nova Reel; ignored otherwise).
    public func outputURI(_ uri: String) -> Video { with { $0.outputURIValue = uri } }

    /// Opt into raw poll bodies on the returned `VideoResponse` (ADR-014).
    public func raw(_ enabled: Bool = true) -> Video { with { $0.rawOptIn = enabled } }

    /// Register a middleware hook (observation + pre-phase veto).
    public func addMiddleware(_ hook: @escaping MiddlewareFn) -> Video {
        with { $0.middleware.append(hook) }
    }

    /// Submit an asynchronous text-to-video (or image-to-video) job and return
    /// the live `VideoJob`. Pre-flight validation rejects unknown models,
    /// unsupported part kinds, and image-to-video on text-only models before any
    /// HTTP call. Fires the `videoGeneration` middleware op pre + post around the
    /// HTTP submit (not the poll loop — batch-submit semantics).
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
        let variant = try validate(parts: parts, model: model, modelDef: modelDef, vgCfg: vgCfg, slug: config.slug)

        let baseEvent = Event(op: .videoGeneration, provider: provider.rawValue, model: model)
        let start = Date()
        try Middleware.firePre(middleware, baseEvent)

        var postEvent = baseEvent
        do {
            let id = try await dispatchSubmit(
                config: config, vgCfg: vgCfg, variant: variant, model: model, parts: parts
            )
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

    /// Clone-on-chain helper: copy, mutate, return.
    func with(_ mutate: (inout Video) -> Void) -> Video {
        var copy = self
        mutate(&copy)
        return copy
    }

    // MARK: - Parts

    /// The internal video-input atom: prompt text plus optional seed frames.
    enum VideoPart {
        case text(String)
        case image(MediaRef)

        var isImage: Bool { if case .image = self { return true }; return false }
    }

    /// Prompt-only hot path, or (when seed frames were attached) the parts path
    /// with the prompt text appended last. Both empty is a validation error.
    private func normalizeParts(_ prompt: String) throws -> [VideoPart] {
        let texts = ([textParts, [prompt]].flatMap { $0 }).filter { !$0.isEmpty }
        if !inputImages.isEmpty {
            return inputImages.map { VideoPart.image($0) } + texts.map { VideoPart.text($0) }
        }
        guard !texts.isEmpty else {
            throw LLMKitError.validation(field: "prompt", message: "set either prompt or parts")
        }
        return texts.map { VideoPart.text($0) }
    }

    private func joinPromptText(_ parts: [VideoPart]) -> String {
        parts.compactMap { if case let .text(s) = $0, !s.isEmpty { return s }; return nil }
            .joined(separator: "\n")
    }

    // MARK: - Validation

    /// Pre-flight rejects: image-to-video only on `supportsImageToVideo` models
    /// (else the seed frame would silently drop at wire time), and output-uri
    /// providers require the caller S3 URI (VID-005). Returns the request
    /// variant the parts select (ADR-096). Mirror of Go's `submitVideo`.
    private func validate(
        parts: [VideoPart], model: String, modelDef: VideoModelDef, vgCfg: VideoGenDef, slug: String
    ) throws -> RequestVariant {
        let imageCount = parts.filter(\.isImage).count
        if imageCount > 0, !modelDef.supportsImageToVideo {
            throw LLMKitError.validation(
                field: "parts",
                message: "\(model) is a text-to-video-only model and does not accept image parts"
            )
        }
        try validateFrames(modelDef: modelDef, imageCount: imageCount)
        try validateOptions(modelDef: modelDef, vgCfg: vgCfg, slug: slug)
        // ADR-096: the carried inputs select the submit request; a config with
        // no such variant cannot send it.
        let variant = try selectRequestVariant(
            provider: slug, variants: vgCfg.variants, carries: carries(imageCount: imageCount))
        if vgCfg.requiresOutputURI, outputURIValue.isEmpty {
            throw LLMKitError.validation(
                field: "output_uri",
                message: "\(providerConfig(provider).slug) requires a caller output S3 URI; set outputURI on the request"
            )
        }
        return variant
    }

    /// The most asset reference images a Veo request takes (Gemini API and
    /// Vertex Veo pages, read 2026-10-15).
    static let maxReferenceImages = 3

    /// Rejects a last frame or reference images the model or the request
    /// cannot carry, before any HTTP call (BUG-089). Same rules, order and
    /// messages as Go's `validateVideoFrames`.
    private func validateFrames(modelDef: VideoModelDef, imageCount: Int) throws {
        let refs = referenceImages.count
        let last = lastFrameImage != nil
        if last, !modelDef.supportsLastFrame {
            throw LLMKitError.validation(
                field: "last_frame", message: "\(modelDef.modelId) does not accept a last frame")
        }
        if refs > 0, !modelDef.supportsReferenceImages {
            throw LLMKitError.validation(
                field: "reference_images", message: "\(modelDef.modelId) does not accept reference images")
        }
        if refs > Self.maxReferenceImages {
            throw LLMKitError.validation(
                field: "reference_images",
                message: "at most \(Self.maxReferenceImages) reference images, got \(refs)")
        }
        if refs > 0, imageCount > 0 || last {
            // Live 2026-10-15: Veo answers 400 "Unsupported video generation
            // request"; Vertex documents the inputs as exclusive.
            throw LLMKitError.validation(
                field: "reference_images", message: "cannot be combined with a first or last frame")
        }
        if last, imageCount == 0 {
            throw LLMKitError.validation(field: "last_frame", message: "requires a first frame")
        }
    }

    /// Rejects a duration, aspect ratio or resolution the provider or the model
    /// cannot take, before any HTTP call (HANDOFF-097). Same rules, order and
    /// messages as Go's `validateVideoOptions`:
    ///  1. A set option on a wire shape other than VideoOpenRouter, naming the
    ///     first set one in the order duration, aspect_ratio, resolution.
    ///  2. A negative duration.
    ///  3. A duration above the model's `maxDurationSeconds` (0 = no known limit).
    ///  4. A resolution the model does not list (empty list = no fixed set).
    ///  5. An aspect ratio the model does not list (empty list = no fixed set).
    private func validateOptions(modelDef: VideoModelDef, vgCfg: VideoGenDef, slug: String) throws {
        if vgCfg.wireShape != "VideoOpenRouter" {
            let set = [
                ("duration", durationSeconds != 0),
                ("aspect_ratio", !aspectRatioValue.isEmpty),
                ("resolution", !resolutionValue.isEmpty),
            ]
            if let (field, _) = set.first(where: { $0.1 }) {
                throw LLMKitError.validation(field: field, message: "\(slug) video does not send \(field)")
            }
            return
        }
        let max = modelDef.maxDurationSeconds
        if durationSeconds < 0 {
            throw LLMKitError.validation(field: "duration", message: "must be positive")
        }
        if durationSeconds > 0, max > 0, durationSeconds > max {
            throw LLMKitError.validation(
                field: "duration",
                message: "\(modelDef.modelId) takes at most \(max) seconds, got \(durationSeconds)")
        }
        if !resolutionValue.isEmpty, !modelDef.resolutions.isEmpty,
           !modelDef.resolutions.contains(resolutionValue) {
            throw LLMKitError.validation(
                field: "resolution", message: "\(modelDef.modelId) does not support resolution \(resolutionValue)")
        }
        if !aspectRatioValue.isEmpty, !modelDef.aspectRatios.isEmpty,
           !modelDef.aspectRatios.contains(aspectRatioValue) {
            throw LLMKitError.validation(
                field: "aspect_ratio",
                message: "\(modelDef.modelId) does not support aspect ratio \(aspectRatioValue)")
        }
    }

    /// The request's carried inputs (ADR-096): reference images, a seed frame
    /// with an optional last frame, or text only.
    private func carries(imageCount: Int) -> [String] {
        if !referenceImages.isEmpty { return [CarriedInput.withReferenceImages] }
        if imageCount > 0, lastFrameImage != nil {
            return [CarriedInput.withSeedFrame, CarriedInput.withLastFrame]
        }
        return partsCarry(imageCount: imageCount, imageInput: CarriedInput.withSeedFrame)
    }

    /// One OpenRouter frame_images item.
    private func openRouterFrame(_ media: MediaRef, _ frameType: String) -> JSONValue {
        let url = "data:\(seedMime(media));base64,\(Data(media.bytes).base64EncodedString())"
        return .object([
            ("type", .string("image_url")),
            ("image_url", .object([("url", .string(url))])),
            ("frame_type", .string(frameType)),
        ])
    }

    /// A Veo image object: raw base64 bytes and the MIME type.
    private func veoImage(_ media: MediaRef) -> JSONValue {
        .object([
            ("bytesBase64Encoded", .string(Data(media.bytes).base64EncodedString())),
            ("mimeType", .string(seedMime(media))),
        ])
    }

    // MARK: - Submit dispatch (selected by wireShape, never provider name)

    /// POSTs the submit body per wire shape and returns the provider-assigned
    /// poll handle id (read from the config-declared `submitHandleField` dotted
    /// path). The submit endpoint is the selected request variant's (ADR-096).
    /// SigV4 providers (Bedrock) sign the exact bytes.
    func dispatchSubmit(
        config: ProviderSpec, vgCfg: VideoGenDef, variant: RequestVariant, model: String, parts: [VideoPart]
    ) async throws -> String {
        let base = videoBaseURL(config: config, vgCfg: vgCfg)
        var headers = RequestBuilder.buildAuthHeaders(config: config, apiKey: apiKey)
        headers.append(("content-type", "application/json"))

        let body: JSONValue
        switch vgCfg.wireShape {
        case "VideoQwen":
            // DashScope's async submit requires this header; per-request only.
            headers.append(("X-DashScope-Async", "enable"))
            body = .object([
                ("model", .string(model)),
                ("input", .object([("prompt", .string(joinPromptText(parts)))])),
            ])
        case "VideoPixVerse":
            // All five fields required; the generic surface is prompt-only, so
            // duration/quality/aspect_ratio are reference-anchored defaults. The
            // per-request Ai-trace-id (PixVerse's anti-cache key) is set per-call.
            headers.append(("Ai-trace-id", Self.newTraceID()))
            body = .object([
                ("model", .string(model)),
                ("prompt", .string(joinPromptText(parts))),
                ("duration", .int(5)),
                ("quality", .string("540p")),
                ("aspect_ratio", .string("16:9")),
            ])
        case "VideoVeo", "VideoVertexVeo":
            // Veo / Vertex Veo carry the model in the submit PATH
            // (:predictLongRunning), so the body has no model field.
            var instance: [(String, JSONValue)] = [("prompt", .string(joinPromptText(parts)))]
            // First frame (BUG-089): the seed rides at instances[0].image as raw
            // base64 + mimeType (no data: prefix), per the Vertex Veo reference
            // (read 2026-10-15). The Gemini API shape is not yet live-verified.
            if let seed = try seedImage(parts) {
                instance.append(("image", veoImage(seed)))
            }
            // Last frame and asset reference images (BUG-089): same
            // {bytesBase64Encoded, mimeType} wrapper. Reference images force an
            // 8-second video, sent as the NUMBER 8 on both APIs (live
            // 2026-10-15: the Gemini API rejects the string "8" its docs show).
            if let last = lastFrameImage {
                instance.append(("lastFrame", veoImage(last)))
            }
            if referenceImages.isEmpty {
                body = .object([("instances", .array([.object(instance)]))])
            } else {
                instance.append(("referenceImages", .array(referenceImages.map {
                    .object([("image", veoImage($0)), ("referenceType", .string("asset"))])
                })))
                body = .object([
                    ("instances", .array([.object(instance)])),
                    ("parameters", .object([("durationSeconds", .int(8))])),
                ])
            }
        case "VideoBedrock":
            // Nova Reel carries the model in the BODY (modelId) and writes the
            // mp4 to the caller's S3 bucket.
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
        case "VideoOpenRouter":
            // Image-to-video (HANDOFF-091): each frame is an OpenRouter
            // ContentPartImage plus frame_type, first_frame then last_frame
            // (live probe 2026-10-18; openrouter.ai/openapi.json).
            var pairs: [(String, JSONValue)] = [
                ("model", .string(model)),
                ("prompt", .string(joinPromptText(parts))),
            ]
            if let seed = try seedImage(parts) {
                var frames = [openRouterFrame(seed, "first_frame")]
                if let last = lastFrameImage { frames.append(openRouterFrame(last, "last_frame")) }
                pairs.append(("frame_images", .array(frames)))
            }
            // Video options (HANDOFF-097): body-root fields, each sent only when
            // set, so the prompt-only body stays {model, prompt}. duration is a
            // JSON integer; validateOptions has already checked each value.
            if durationSeconds > 0 { pairs.append(("duration", .int(Int64(durationSeconds)))) }
            if !aspectRatioValue.isEmpty { pairs.append(("aspect_ratio", .string(aspectRatioValue))) }
            if !resolutionValue.isEmpty { pairs.append(("resolution", .string(resolutionValue))) }
            body = .object(pairs)
        case "VideoGrok", "VideoZhipu", "VideoVidu", "VideoTogether", "VideoMinimax":
            // Shared {model, prompt} arm (Grok / Zhipu / Vidu / Together /
            // MiniMax). Image-to-video (BUG-010): a seed frame inlines as a data
            // URL at xAI's image.url field (absent on the text-to-video hot path).
            var pairs: [(String, JSONValue)] = [
                ("model", .string(model)),
                ("prompt", .string(joinPromptText(parts))),
            ]
            if let seed = try seedImageURL(parts) {
                pairs.append(("image", .object([("url", .string(seed))])))
            }
            body = .object(pairs)
        default:
            throw LLMKitError.unsupported("video submit: unsupported wire shape \"\(vgCfg.wireShape)\"")
        }

        // {model} in the submit endpoint is substituted with the per-call model
        // (Veo's :predictLongRunning path); a no-op for body-model providers.
        let url = appendQueryAuth(
            base + variant.endpoint.replacingOccurrences(of: "{model}", with: model),
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

    /// The single image-to-video seed frame (Grok, BUG-010; Veo first frame,
    /// BUG-089). Returns nil on the text-to-video hot path; errors on more than
    /// one seed frame (a single-frame condition, so rejecting is honest).
    private func seedImage(_ parts: [VideoPart]) throws -> MediaRef? {
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
        return seed
    }

    /// The seed frame's MIME, defaulting to image/png.
    private func seedMime(_ media: MediaRef) -> String {
        media.mimeType.isEmpty ? "image/png" : media.mimeType
    }

    /// The Grok image-to-video seed-frame data URL (BUG-010). Returns nil on the
    /// text-to-video hot path.
    private func seedImageURL(_ parts: [VideoPart]) throws -> String? {
        guard let media = try seedImage(parts) else { return nil }
        return "data:\(seedMime(media));base64,\(Data(media.bytes).base64EncodedString())"
    }

    /// Video API base (Option D): a per-client override wins, else the provider's
    /// distinct video base when set, else the chat base — with `{region}`
    /// resolved from the region env var (a no-op without the placeholder).
    private func videoBaseURL(config: ProviderSpec, vgCfg: VideoGenDef) -> String {
        VideoWire.baseURL(config: config, vgCfg: vgCfg, override: baseURLOverride)
    }

    /// Appends the provider's query-param API key (Google `?key=`) to a video
    /// URL; a no-op for header-auth providers. Mirror of `append_video_auth`.
    private func appendQueryAuth(_ url: String, config: ProviderSpec) -> String {
        VideoWire.appendQueryAuth(url, config: config, apiKey: apiKey)
    }

    /// A UUID-shaped, unique-per-request trace id for providers that require one
    /// (PixVerse's `Ai-trace-id`, an anti-cache key). Foundation's `UUID` is a
    /// real v4 UUID (the Rust twin hand-rolls one only to stay dependency-free).
    static func newTraceID() -> String { UUID().uuidString.lowercased() }
}

/// The live video-generation handle: the persistable `VideoHandle` value plus the
/// credentials + transport needed to poll it (mirror of `BatchJob`).
public final class VideoJob: Sendable {
    /// The persistable identity value (ADR-014 cross-process resume).
    public let handle: VideoHandle
    let apiKey: String
    let http: HTTPClient
    let baseURLOverride: String?
    /// Poll cadence for `wait` (tests shrink these via `cadence`; defaults match Rust/Go).
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

    /// A copy with the same identity + transport and the given poll cadence
    /// (internal test seam).
    func cadence(interval: TimeInterval, timeout: TimeInterval) -> VideoJob {
        VideoJob(
            handle: handle, apiKey: apiKey, http: http, baseURLOverride: baseURLOverride,
            interval: interval, timeout: timeout
        )
    }

    /// One normalized poll round-trip (ADR-063 POLL-001): no loop.
    public func poll() async throws -> JobStatus<VideoResponse> {
        try await Job.pollOnce(try makeAdapter())
    }

    /// Poll until a terminal state, returning the finished `VideoResponse`.
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
