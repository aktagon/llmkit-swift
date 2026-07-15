import Foundation

/// Image-generation runtime (ADR-036 wire-conformance) — a port of Rust's
/// `image.rs`. Synchronous: `client.image.<config>.generate(prompt)` builds the
/// provider request body, sends it once, and parses the reply into the universal
/// `ImageResponse`.
///
/// The generated `imageGenConfig(provider)` fact selects both the request body
/// shape (`inputMode`) and the response parser (`responseShape`) — never the
/// provider name (BUG-024). Pre-flight validation rejects unsupported aspect
/// ratios / sizes / reference-image counts before any HTTP call.
///
/// Scope: the JSON generation path for every provider. OpenAI's
/// `multipart/form-data` edit branch is a documented wire exclusion (WIRE-008)
/// and is not implemented here.
public struct Image: Sendable {
    let provider: ProviderName
    let apiKey: String
    let baseURLOverride: String?
    let http: HTTPClient
    var modelOverride: String?
    var options = ImageOptions()
    /// Accumulated reference images for the edit path (caller order preserved).
    var inputImages: [MediaRef] = []

    init(provider: ProviderName, apiKey: String, baseURLOverride: String?, http: HTTPClient) {
        self.provider = provider
        self.apiKey = apiKey
        self.baseURLOverride = baseURLOverride
        self.http = http
    }

    /// Select the image-generation model.
    public func model(_ model: String) -> Image { with { $0.modelOverride = model } }

    /// Request an aspect ratio (validated against the model's whitelist).
    public func aspectRatio(_ value: String) -> Image { with { $0.options.aspectRatio = value } }

    /// Request an image size (validated against the model's whitelist; OpenAI /
    /// Recraft take a `WxH` size passed through unchecked).
    public func imageSize(_ value: String) -> Image { with { $0.options.imageSize = value } }

    /// Ask the provider to return text alongside the image (Google only).
    public func includeText() -> Image { with { $0.options.includeText = true } }

    /// OpenAI gpt-image-* quality (low|medium|high|auto).
    public func quality(_ value: String) -> Image { with { $0.options.quality = value } }

    /// OpenAI gpt-image-* output MIME format (png|webp|jpeg).
    public func outputFormat(_ value: String) -> Image { with { $0.options.outputFormat = value } }

    /// OpenAI gpt-image-* background treatment (transparent|opaque|auto).
    public func background(_ value: String) -> Image { with { $0.options.background = value } }

    /// Number of images to generate; wire field `n` (OpenAI + Recraft + xAI).
    public func count(_ value: Int) -> Image { with { $0.options.count = value } }

    /// Attach a reference image for the edit path. The bytes are base64-encoded
    /// at wire time. Multiple `.image(...)` calls accumulate in caller order.
    public func image(_ mimeType: String, _ data: Data) -> Image {
        with { $0.inputImages.append(MediaRef(mimeType: mimeType, bytes: [UInt8](data))) }
    }

    /// Register a middleware hook (observation + pre-phase veto).
    public func addMiddleware(_ hook: @escaping MiddlewareFn) -> Image {
        with { $0.options.middleware.append(hook) }
    }

    /// Build and send the image request, returning the decoded `ImageResponse`.
    /// Fires the `imageGeneration` middleware op (pre-phase veto, post-phase
    /// observation with usage).
    public func generate(_ prompt: String) async throws -> ImageResponse {
        guard !apiKey.isEmpty else {
            throw LLMKitError.validation(field: "api_key", message: "required")
        }
        guard let model = modelOverride, !model.isEmpty else {
            throw LLMKitError.validation(field: "model", message: "required for image generation")
        }
        let parts = try normalizeParts(prompt)

        let config = providerConfig(provider)
        guard let imgCfg = imageGenConfig(provider) else {
            throw LLMKitError.validation(field: "provider", message: "\(config.slug) does not support image generation")
        }
        guard let modelDef = imgCfg.models.first(where: { $0.modelId == model }) else {
            throw LLMKitError.validation(field: "model", message: "\(model) is not a known image-generation model for \(config.slug)")
        }
        try validate(parts: parts, model: model, modelDef: modelDef, imgCfg: imgCfg, slug: config.slug)

        let baseEvent = Event(op: .imageGeneration, provider: provider.rawValue, model: model)
        let start = Date()
        try Middleware.firePre(options.middleware, baseEvent)

        var postEvent = baseEvent
        do {
            let response = try await send(parts: parts, model: model, imgCfg: imgCfg, config: config)
            postEvent.duration = Date().timeIntervalSince(start)
            postEvent.usage = response.usage
            Middleware.firePost(options.middleware, postEvent)
            return response
        } catch {
            postEvent.duration = Date().timeIntervalSince(start)
            postEvent.err = "\(error)"
            Middleware.firePost(options.middleware, postEvent)
            throw error
        }
    }

    /// Clone-on-chain helper: copy, mutate, return.
    private func with(_ mutate: (inout Image) -> Void) -> Image {
        var copy = self
        mutate(&copy)
        return copy
    }

    // MARK: - Parts

    /// The internal image-input atom: either the accumulated reference images
    /// followed by the prompt text (edit path), or the bare prompt text
    /// (generation path). Mirrors Rust's `Part`.
    private enum ImagePart {
        case text(String)
        case image(MediaRef)

        var isImage: Bool { if case .image = self { return true }; return false }
    }

    /// Enforce the prompt-XOR-parts rule and produce the canonical part list. A
    /// chain that accumulated reference images uses the parts path (text appended
    /// last); otherwise the prompt sugar path. Both empty is a validation error.
    private func normalizeParts(_ prompt: String) throws -> [ImagePart] {
        if !inputImages.isEmpty {
            var parts = inputImages.map { ImagePart.image($0) }
            if !prompt.isEmpty { parts.append(.text(prompt)) }
            return parts
        }
        guard !prompt.isEmpty else {
            throw LLMKitError.validation(field: "prompt", message: "set either prompt or parts")
        }
        return [.text(prompt)]
    }

    private func joinText(_ parts: [ImagePart]) -> String {
        parts.compactMap { if case let .text(s) = $0, !s.isEmpty { return s }; return nil }
            .joined(separator: "\n")
    }

    // MARK: - Validation

    /// Per-provider pre-flight rejects. Aspect ratio / size are checked against
    /// the model whitelist (empty = pass-through); reference-image count against
    /// `maxInputCount`; the OpenAI-only knobs (quality / output_format /
    /// background / count) are rejected on the wire shapes that do not accept
    /// them. Mirror of `generate_image`'s validation block.
    private func validate(
        parts: [ImagePart], model: String, modelDef: ImageModelDef, imgCfg: ImageGenDef, slug: String
    ) throws {
        if let ratio = options.aspectRatio, !modelDef.aspectRatios.isEmpty, !modelDef.aspectRatios.contains(ratio) {
            throw LLMKitError.validation(field: "aspect_ratio", message: "\(ratio) not supported by \(model)")
        }
        if let size = options.imageSize, !modelDef.imageSizes.isEmpty, !modelDef.imageSizes.contains(size) {
            throw LLMKitError.validation(field: "image_size", message: "\(size) not supported by \(model)")
        }
        let imageCount = parts.filter(\.isImage).count
        if imageCount > imgCfg.maxInputCount {
            throw LLMKitError.validation(
                field: "parts",
                message: "\(imageCount) image parts exceeds maximum \(imgCfg.maxInputCount) for \(slug)"
            )
        }

        // Per-provider knob validation. Quality / output_format / background are
        // OpenAI-only on the wire; count (n) is OpenAI + Recraft + xAI. Recraft
        // additionally has no aspect_ratio wire field (it sizes by WxH).
        switch imgCfg.inputMode {
        case "InlineParts":
            try reject(options.quality, "quality", slug)
            try reject(options.outputFormat, "output_format", slug)
            try reject(options.background, "background", slug)
            try reject(options.count.map { String($0) }, "count", slug)
        case "JSONInlineRefs":
            try reject(options.quality, "quality", slug)
            try reject(options.outputFormat, "output_format", slug)
            try reject(options.background, "background", slug)
        case "JSONPredict":
            try reject(options.quality, "quality", slug)
            try reject(options.outputFormat, "output_format", slug)
            try reject(options.background, "background", slug)
        case "JSONGenerations":
            if options.aspectRatio != nil {
                throw LLMKitError.validation(
                    field: "aspect_ratio",
                    message: "not supported by \(slug); use image_size (Recraft sizes by WxH)"
                )
            }
            try reject(options.quality, "quality", slug)
            try reject(options.outputFormat, "output_format", slug)
            try reject(options.background, "background", slug)
        default:
            break // MultipartForm: quality / output_format / background / count all valid
        }
    }

    private func reject(_ value: String?, _ field: String, _ slug: String) throws {
        if value != nil {
            throw LLMKitError.validation(field: field, message: "not supported by \(slug)")
        }
    }

    // MARK: - Send

    private func send(
        parts: [ImagePart], model: String, imgCfg: ImageGenDef, config: ProviderSpec
    ) async throws -> ImageResponse {
        let base = baseURLOverride ?? config.baseURL
        let headers = RequestBuilder.buildAuthHeaders(config: config, apiKey: apiKey)
        let hasImages = parts.contains(where: \.isImage)

        let url: String
        let body: JSONValue
        switch imgCfg.inputMode {
        case "JSONInlineRefs":
            body = hasImages ? buildXAIEditBody(parts, model) : buildXAIGenBody(parts, model)
            url = base + (hasImages ? imgCfg.editEndpoint : imgCfg.genEndpoint)
        case "JSONGenerations":
            body = buildRecraftBody(parts, model)
            url = base + imgCfg.genEndpoint
        case "MultipartForm":
            guard !hasImages else {
                throw LLMKitError.unsupported("image editing (multipart/form-data) is not supported by the Swift SDK (WIRE-008)")
            }
            body = buildOpenAIBody(parts, model)
            url = base + imgCfg.genEndpoint
        case "JSONPredict":
            body = buildVertexBody(parts)
            url = RequestBuilder.buildURL(
                config: config, endpoint: config.endpoint, apiKey: apiKey, model: model, baseURLOverride: baseURLOverride
            )
        default: // InlineParts (Google generateContent)
            body = buildGoogleBody(parts)
            url = RequestBuilder.buildURL(
                config: config, endpoint: config.endpoint, apiKey: apiKey, model: model, baseURLOverride: baseURLOverride
            )
        }

        let (statusCode, data) = try await http.postJSON(url: url, body: body, headers: headers)
        guard (200..<300).contains(statusCode) else {
            throw ResponseParser.parseError(config: config, statusCode: statusCode, body: data)
        }
        let raw = try JSONValue.parse(String(decoding: data, as: UTF8.self))
        // Response parser selected by config shape, never provider name (BUG-024).
        return parseResponse(raw, imgCfg)
    }

    // MARK: - Request bodies

    /// Google `generateContent` body (InlineParts): a single content turn whose
    /// parts carry text and `inlineData` images in caller order, plus the
    /// `generationConfig` response modalities + optional `imageConfig`.
    private func buildGoogleBody(_ parts: [ImagePart]) -> JSONValue {
        var wire: [JSONValue] = []
        for part in parts {
            switch part {
            case let .text(text):
                wire.append(.object([("text", .string(text))]))
            case let .image(media):
                wire.append(.object([("inlineData", .object([
                    ("mimeType", .string(media.mimeType)),
                    ("data", .string(Data(media.bytes).base64EncodedString())),
                ]))]))
            }
        }
        let modalities: [JSONValue] = options.includeText
            ? [.string("TEXT"), .string("IMAGE")]
            : [.string("IMAGE")]
        var generationConfig: [(String, JSONValue)] = [("responseModalities", .array(modalities))]
        var imageConfig: [(String, JSONValue)] = []
        if let ratio = options.aspectRatio { imageConfig.append(("aspectRatio", .string(ratio))) }
        if let size = options.imageSize { imageConfig.append(("imageSize", .string(size))) }
        if !imageConfig.isEmpty {
            generationConfig.append(("imageConfig", .object(imageConfig)))
        }
        return .object([
            ("contents", .array([.object([("parts", .array(wire))])])),
            ("generationConfig", .object(generationConfig)),
        ])
    }

    /// OpenAI `/v1/images/generations` JSON body. gpt-image-* always returns
    /// base64 and rejects `response_format`, so it is never set.
    private func buildOpenAIBody(_ parts: [ImagePart], _ model: String) -> JSONValue {
        var body: [(String, JSONValue)] = [
            ("model", .string(model)),
            ("prompt", .string(joinText(parts))),
        ]
        if let size = options.imageSize { body.append(("size", .string(size))) }
        if let quality = options.quality { body.append(("quality", .string(quality))) }
        if let format = options.outputFormat { body.append(("output_format", .string(format))) }
        if let background = options.background { body.append(("background", .string(background))) }
        if let count = options.count { body.append(("n", .int(Int64(count)))) }
        return .object(body)
    }

    /// Recraft `/v1/images/generations` JSON body. `response_format` is forced to
    /// `b64_json` (Recraft defaults to URL delivery) so the decode path is
    /// uniform; vector/SVG output is selected by the model id, not a body flag.
    private func buildRecraftBody(_ parts: [ImagePart], _ model: String) -> JSONValue {
        var body: [(String, JSONValue)] = [
            ("model", .string(model)),
            ("prompt", .string(joinText(parts))),
            ("response_format", .string("b64_json")),
        ]
        if let size = options.imageSize { body.append(("size", .string(size))) }
        if let count = options.count { body.append(("n", .int(Int64(count)))) }
        return .object(body)
    }

    /// xAI Grok `/v1/images/generations` JSON body. `image_size` maps to
    /// `resolution` (xAI's name); `response_format=b64_json` is forced (xAI
    /// defaults to URL).
    private func buildXAIGenBody(_ parts: [ImagePart], _ model: String) -> JSONValue {
        var body: [(String, JSONValue)] = [
            ("model", .string(model)),
            ("prompt", .string(joinText(parts))),
            ("response_format", .string("b64_json")),
        ]
        if let ratio = options.aspectRatio { body.append(("aspect_ratio", .string(ratio))) }
        if let size = options.imageSize { body.append(("resolution", .string(size))) }
        if let count = options.count { body.append(("n", .int(Int64(count)))) }
        return .object(body)
    }

    /// xAI Grok `/v1/images/edits` body: one reference image maps to
    /// `image: {url: "data:..."}`, multiple to `images: [...]` in caller order.
    private func buildXAIEditBody(_ parts: [ImagePart], _ model: String) -> JSONValue {
        guard case var .object(body) = buildXAIGenBody(parts, model) else { return .object([]) }
        let refs: [JSONValue] = parts.compactMap { part in
            guard case let .image(media) = part else { return nil }
            let mime = media.mimeType.isEmpty ? "image/png" : media.mimeType
            let dataURL = "data:\(mime);base64,\(Data(media.bytes).base64EncodedString())"
            return .object([("url", .string(dataURL))])
        }
        if refs.count == 1 {
            JSONObject.set(&body, "image", refs[0])
        } else if refs.count > 1 {
            JSONObject.set(&body, "images", .array(refs))
        }
        return .object(body)
    }

    /// Vertex AI Imagen `:predict` body: an `instances`/`parameters` envelope.
    /// The instance carries the prompt and (for editing) a single reference
    /// image; parameters carries `sampleCount` + optional `aspectRatio`.
    private func buildVertexBody(_ parts: [ImagePart]) -> JSONValue {
        var instance: [(String, JSONValue)] = [("prompt", .string(joinText(parts)))]
        for part in parts {
            if case let .image(media) = part {
                instance.append(("image", .object([
                    ("bytesBase64Encoded", .string(Data(media.bytes).base64EncodedString())),
                ])))
                break // Vertex Imagen takes a single edit-target image
            }
        }
        var parameters: [(String, JSONValue)] = [("sampleCount", .int(Int64(options.count ?? 1)))]
        if let ratio = options.aspectRatio { parameters.append(("aspectRatio", .string(ratio))) }
        return .object([
            ("instances", .array([.object(instance)])),
            ("parameters", .object(parameters)),
        ])
    }

    // MARK: - Response parsing (selected by responseShape, never provider name)

    private func parseResponse(_ raw: JSONValue, _ cfg: ImageGenDef) -> ImageResponse {
        switch cfg.responseShape {
        case "DataArrayB64Json":
            return parseDataArray(raw, inputPath: cfg.usageInputPath, outputPath: cfg.usageOutputPath)
        case "VertexPredictions":
            return parseVertexResponse(raw)
        default: // GoogleParts
            return parseGoogleParts(raw, cfg)
        }
    }

    /// OpenAI / xAI / Recraft `data[].b64_json` shape. SVG bytes (Recraft vector
    /// models) are sniffed to `image/svg+xml` when the provider echoes no mime.
    private func parseDataArray(_ raw: JSONValue, inputPath: String, outputPath: String) -> ImageResponse {
        var images: [ImageData] = []
        var revised: [String] = []
        if case let .array(entries)? = raw.member("data") {
            for entry in entries {
                if case let .string(b64)? = entry.member("b64_json"), !b64.isEmpty,
                   let decoded = Data(base64Encoded: b64) {
                    var mime = "image/png"
                    if case let .string(echoed)? = entry.member("mime_type"), !echoed.isEmpty {
                        mime = echoed
                    }
                    let bytes = [UInt8](decoded)
                    if mime == "image/png", looksLikeSVG(bytes) { mime = "image/svg+xml" }
                    images.append(ImageData(mimeType: mime, bytes: bytes))
                }
                if case let .string(rp)? = entry.member("revised_prompt"), !rp.isEmpty {
                    revised.append(rp)
                }
            }
        }
        let usage = Usage(
            input: inputPath.isEmpty ? 0 : raw.intValue(at: inputPath),
            output: outputPath.isEmpty ? 0 : raw.intValue(at: outputPath)
        )
        return ImageResponse(
            images: images, text: revised.joined(separator: "\n"), usage: usage,
            finishReason: "", finishMessage: "", raw: nil
        )
    }

    /// Vertex AI Imagen `:predict` shape: `{predictions: [{bytesBase64Encoded,
    /// mimeType}]}`. Vertex reports no token counts, so usage stays zero.
    private func parseVertexResponse(_ raw: JSONValue) -> ImageResponse {
        var images: [ImageData] = []
        var finishReason = ""
        if case let .array(predictions)? = raw.member("predictions") {
            for entry in predictions {
                if finishReason.isEmpty, case let .string(rai)? = entry.member("raiFilteredReason"), !rai.isEmpty {
                    finishReason = rai
                }
                guard case let .string(b64)? = entry.member("bytesBase64Encoded"), !b64.isEmpty,
                      let decoded = Data(base64Encoded: b64) else { continue }
                var mime = "image/png"
                if case let .string(echoed)? = entry.member("mimeType"), !echoed.isEmpty { mime = echoed }
                images.append(ImageData(mimeType: mime, bytes: [UInt8](decoded)))
            }
        }
        return ImageResponse(
            images: images, text: "", usage: Usage(),
            finishReason: finishReason, finishMessage: "", raw: nil
        )
    }

    /// Google `candidates[].content.parts` inline-data shape.
    private func parseGoogleParts(_ raw: JSONValue, _ cfg: ImageGenDef) -> ImageResponse {
        var images: [ImageData] = []
        var text = ""
        var finishReason = ""
        var finishMessage = ""
        if case let .array(candidates)? = raw.member("candidates"), let first = candidates.first {
            if case let .string(fr)? = first.member("finishReason") { finishReason = fr }
            if case let .string(fm)? = first.member("finishMessage") { finishMessage = fm }
            if case let .array(parts)? = first.lookup("content.parts") {
                for part in parts {
                    if let inline = part.member("inlineData"),
                       case let .string(data)? = inline.member("data"), !data.isEmpty,
                       let decoded = Data(base64Encoded: data) {
                        var mime = ""
                        if case let .string(m)? = inline.member("mimeType") { mime = m }
                        images.append(ImageData(mimeType: mime, bytes: [UInt8](decoded)))
                    }
                    if case let .string(t)? = part.member("text"), !t.isEmpty { text += t }
                }
            }
        }
        let usage = Usage(
            input: cfg.usageInputPath.isEmpty ? 0 : raw.intValue(at: cfg.usageInputPath),
            output: cfg.usageOutputPath.isEmpty ? 0 : raw.intValue(at: cfg.usageOutputPath)
        )
        return ImageResponse(
            images: images, text: text, usage: usage,
            finishReason: finishReason, finishMessage: finishMessage, raw: nil
        )
    }

    /// Whether the decoded bytes are an SVG document (XML prolog or `<svg` root).
    /// Used to label vector-model output when the provider echoes no mime type.
    private func looksLikeSVG(_ data: [UInt8]) -> Bool {
        let text = String(decoding: data, as: UTF8.self)
        let trimmed = text.drop { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" }
        return trimmed.hasPrefix("<?xml") || trimmed.hasPrefix("<svg")
    }
}

/// The accumulated image-generation parameters carried by the `Image` builder.
/// Internal — the public surface is the builder chain.
struct ImageOptions: Sendable {
    var aspectRatio: String?
    var imageSize: String?
    var includeText: Bool = false
    var quality: String?
    var outputFormat: String?
    var background: String?
    var count: Int?
    var middleware: [MiddlewareFn] = []
}
