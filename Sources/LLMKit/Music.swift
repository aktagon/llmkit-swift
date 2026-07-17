import Foundation

/// Music-generation runtime — a port of Rust's `music.rs` (ADR-033). Synchronous:
/// `client.music.<config>.generate(prompt)` builds the provider request body,
/// sends it once, and parses the reply into the universal `MusicResponse`.
///
/// Dispatch branches on the generated `musicGenConfig(provider).wireShape` —
/// never the provider name — which fully determines the request body, the
/// response audio path, AND the byte encoding (base64 vs hex):
///
///   - MusicPredict (Vertex Lyria): instances/parameters envelope to :predict;
///     audio at predictions[].audioContent (base64 WAV).
///   - MusicMinimax: top-level model/prompt/lyrics/audio_setting to the absolute
///     gen endpoint; audio at data.audio (hex).
///   - MusicGenerateContent (Gemini Lyria 3): prompt + lyrics fold into
///     contents[0].parts[].text with responseModalities=["AUDIO"]; audio at
///     candidates[0].content.parts[].inlineData.data (base64).
///
/// Lyrics support is advisory (ADR-037 MUS-008), not gated: lyrics fold into the
/// prompt for the Predict shape and the model ignores or honors them. Fires the
/// `musicGeneration` middleware op pre + post.
public struct Music: Sendable {
    let provider: ProviderName
    let apiKey: String
    let baseURLOverride: String?
    let http: HTTPClient
    var modelOverride: String?
    var options = MusicOptions()
    /// Accumulated text + lyrics parts in caller order (the canonical sequence
    /// path). Empty when the caller uses only the `generate(prompt)` sugar.
    var parts: [MusicPart] = []

    init(provider: ProviderName, apiKey: String, baseURLOverride: String?, http: HTTPClient) {
        self.provider = provider
        self.apiKey = apiKey
        self.baseURLOverride = baseURLOverride
        self.http = http
    }

    /// Select the music-generation model (required — the text-generation default
    /// does not generate audio).
    public func model(_ model: String) -> Music { with { $0.modelOverride = model } }

    /// Append a text part (ordered). Mixing `.text(...)` / `.lyrics(...)` uses the
    /// canonical parts path; a final `generate(prompt)` appends the prompt as a
    /// last text part.
    public func text(_ value: String) -> Music { with { $0.parts.append(.text(value)) } }

    /// Append a lyrics part (ordered). Advisory (ADR-037 MUS-008): instrumental
    /// models fold lyrics into the prompt and ignore them.
    public func lyrics(_ value: String) -> Music { with { $0.parts.append(.lyrics(value)) } }

    /// Opt into `MusicResponse.raw` (the parsed provider body, ADR-014).
    public func raw() -> Music { with { $0.options.raw = true } }

    /// Register a middleware hook (observation + pre-phase veto).
    public func addMiddleware(_ hook: @escaping MiddlewareFn) -> Music {
        with { $0.options.middleware.append(hook) }
    }

    /// Build and send the music request, returning the decoded `MusicResponse`.
    /// `prompt` is terse sugar for the prompt-only hot path; when the chain
    /// accumulated `.text(...)` / `.lyrics(...)` parts, a non-empty `prompt` is
    /// appended as a final text part. Fires the `musicGeneration` middleware op
    /// (pre-phase veto, post-phase observation with usage).
    public func generate(_ prompt: String) async throws -> MusicResponse {
        guard !apiKey.isEmpty else {
            throw LLMKitError.validation(field: "api_key", message: "required")
        }
        guard let model = modelOverride, !model.isEmpty else {
            throw LLMKitError.validation(field: "model", message: "required for music generation")
        }
        let parts = try normalizeParts(prompt)

        let config = providerConfig(provider)
        guard let mgCfg = musicGenConfig(provider) else {
            throw LLMKitError.validation(field: "provider", message: "\(config.slug) does not support music generation")
        }
        guard let modelDef = mgCfg.models.first(where: { $0.modelId == model }) else {
            throw LLMKitError.validation(
                field: "model", message: "\(model) is not a known music-generation model for \(config.slug)"
            )
        }

        let baseEvent = Event(op: .musicGeneration, provider: provider.rawValue, model: model)
        let start = Date()
        try Middleware.firePre(options.middleware, baseEvent)

        var postEvent = baseEvent
        do {
            let response = try await send(parts: parts, model: model, modelDef: modelDef, mgCfg: mgCfg, config: config)
            postEvent.duration = Date().timeIntervalSince(start)
            postEvent.usage = response.usage
            Middleware.firePost(options.middleware, postEvent)
            return response
        } catch {
            postEvent.duration = Date().timeIntervalSince(start)
            postEvent.err = Middleware.errString(error)
            Middleware.firePost(options.middleware, postEvent)
            throw error
        }
    }

    /// Clone-on-chain helper: copy, mutate, return.
    private func with(_ mutate: (inout Music) -> Void) -> Music {
        var copy = self
        mutate(&copy)
        return copy
    }

    // MARK: - Parts

    /// The internal music-input atom: text or lyrics. A music request never
    /// carries image parts — the `Part` enum makes that unrepresentable (the Rust
    /// runtime rejects `Part::Image`; here the case does not exist), so the only
    /// per-part guard the Rust twin keeps is elided.
    enum MusicPart: Sendable {
        case text(String)
        case lyrics(String)
    }

    /// Enforce the prompt-XOR-parts rule and produce the canonical part list.
    /// When the chain accumulated parts, a non-empty `prompt` appends as a final
    /// text part; otherwise the prompt sugar path. Both empty is a validation
    /// error (mirror of `normalize_music_parts`).
    private func normalizeParts(_ prompt: String) throws -> [MusicPart] {
        if !parts.isEmpty {
            var out = parts
            if !prompt.isEmpty { out.append(.text(prompt)) }
            return out
        }
        guard !prompt.isEmpty else {
            throw LLMKitError.validation(field: "prompt", message: "set either prompt or parts")
        }
        return [.text(prompt)]
    }

    private func joinPromptText(_ parts: [MusicPart]) -> String {
        parts.compactMap { if case let .text(s) = $0, !s.isEmpty { return s }; return nil }
            .joined(separator: "\n")
    }

    private func joinLyricsText(_ parts: [MusicPart]) -> String {
        parts.compactMap { if case let .lyrics(s) = $0, !s.isEmpty { return s }; return nil }
            .joined(separator: "\n")
    }

    // MARK: - Send

    private func send(
        parts: [MusicPart], model: String, modelDef: MusicModelDef, mgCfg: MusicGenDef, config: ProviderSpec
    ) async throws -> MusicResponse {
        let base = baseURLOverride ?? config.baseURL
        var headers = RequestBuilder.buildAuthHeaders(config: config, apiKey: apiKey)
        headers.append(("content-type", "application/json"))

        let url: String
        let body: JSONValue
        switch mgCfg.wireShape {
        case "MusicPredict":
            let endpoint = (mgCfg.genEndpoint.isEmpty ? config.endpoint : mgCfg.genEndpoint)
                .replacingOccurrences(of: "{model}", with: model)
            url = base + endpoint
            body = buildVertexBody(parts)
        case "MusicMinimax":
            url = mgCfg.genEndpoint.hasPrefix("http") ? mgCfg.genEndpoint : base + mgCfg.genEndpoint
            body = buildMinimaxBody(parts, model)
        default: // MusicGenerateContent (Gemini)
            let endpoint = mgCfg.genEndpoint.isEmpty ? config.endpoint : mgCfg.genEndpoint
            url = RequestBuilder.buildURL(
                config: config, endpoint: endpoint, apiKey: apiKey, model: model, baseURLOverride: baseURLOverride
            )
            body = buildGeminiBody(parts)
        }

        let (statusCode, data) = try await http.postJSON(url: url, body: body, headers: headers)
        guard (200..<300).contains(statusCode) else {
            throw ResponseParser.parseError(config: config, statusCode: statusCode, body: data)
        }
        let raw = try JSONValue.parse(String(decoding: data, as: UTF8.self))
        var parsed = parseResponse(mgCfg.wireShape, fallbackMime: modelDef.outputMime, raw: raw)
        if options.raw { parsed.raw = raw }
        return parsed
    }

    // MARK: - Request bodies

    /// Vertex AI Lyria :predict body. Lyria 2 has no lyrics wire-slot, so any
    /// lyrics parts fold into the prompt text (ADR-037 MUS-008); the instrumental
    /// model ignores vocal content. instances/parameters envelope mirrors Imagen.
    private func buildVertexBody(_ parts: [MusicPart]) -> JSONValue {
        var prompt = joinPromptText(parts)
        let lyrics = joinLyricsText(parts)
        if !lyrics.isEmpty {
            prompt = prompt.isEmpty ? lyrics : "\(prompt)\n\(lyrics)"
        }
        return .object([
            ("instances", .array([.object([("prompt", .string(prompt))])])),
            ("parameters", .object([("sampleCount", .int(1))])),
        ])
    }

    /// Gemini generateContent body for Lyria 3. Text and lyrics parts both
    /// serialize as {text} parts in caller order (Gemini takes custom lyrics
    /// inline in the prompt text). responseModalities requests AUDIO output.
    private func buildGeminiBody(_ parts: [MusicPart]) -> JSONValue {
        let wire: [JSONValue] = parts.map { part in
            switch part {
            case let .text(s): return .object([("text", .string(s))])
            case let .lyrics(s): return .object([("text", .string(s))])
            }
        }
        return .object([
            ("contents", .array([.object([("parts", .array(wire))])])),
            ("generationConfig", .object([("responseModalities", .array([.string("AUDIO")]))])),
        ])
    }

    /// MiniMax /v1/music_generation body. Prompt parts join into `prompt`;
    /// lyrics parts join into `lyrics`. output_format=hex returns hex-encoded
    /// audio at data.audio.
    private func buildMinimaxBody(_ parts: [MusicPart], _ model: String) -> JSONValue {
        var body: [(String, JSONValue)] = [
            ("model", .string(model)),
            ("prompt", .string(joinPromptText(parts))),
            ("output_format", .string("hex")),
            ("audio_setting", .object([
                ("sample_rate", .int(44100)),
                ("bitrate", .int(128000)),
                ("format", .string("mp3")),
            ])),
        ]
        let lyrics = joinLyricsText(parts)
        if !lyrics.isEmpty { body.append(("lyrics", .string(lyrics))) }
        return .object(body)
    }

    // MARK: - Response parsing (selected by wireShape, never provider name)

    private func parseResponse(_ wireShape: String, fallbackMime: String, raw: JSONValue) -> MusicResponse {
        switch wireShape {
        case "MusicPredict": return parseVertexResponse(raw, fallbackMime)
        case "MusicMinimax": return parseMinimaxResponse(raw, fallbackMime)
        default: return parseGeminiResponse(raw, fallbackMime)
        }
    }

    /// Vertex Lyria :predict responses. Shape:
    /// `{"predictions": [{"audioContent": "<base64>", "mimeType": "audio/wav"}]}`.
    private func parseVertexResponse(_ raw: JSONValue, _ fallbackMime: String) -> MusicResponse {
        var audio: [AudioData] = []
        var finishReason = ""
        if case let .array(preds)? = raw.member("predictions") {
            for entry in preds {
                if finishReason.isEmpty, case let .string(rai)? = entry.member("raiFilteredReason"), !rai.isEmpty {
                    finishReason = rai
                }
                var b64 = ""
                if case let .string(v)? = entry.member("audioContent"), !v.isEmpty {
                    b64 = v
                } else if case let .string(v)? = entry.member("bytesBase64Encoded"), !v.isEmpty {
                    b64 = v
                }
                guard !b64.isEmpty, let decoded = Data(base64Encoded: b64) else { continue }
                var mime = fallbackMime
                if case let .string(echoed)? = entry.member("mimeType"), !echoed.isEmpty { mime = echoed }
                audio.append(AudioData(mimeType: mime, bytes: [UInt8](decoded)))
            }
        }
        return MusicResponse(audio: audio, text: "", usage: Usage(), finishReason: finishReason, finishMessage: "", raw: nil)
    }

    /// Gemini responses. Walks candidates[0].content.parts, decoding each
    /// inlineData audio part and concatenating text parts (generated lyrics).
    private func parseGeminiResponse(_ raw: JSONValue, _ fallbackMime: String) -> MusicResponse {
        guard case let .array(candidates)? = raw.member("candidates"), let first = candidates.first else {
            return MusicResponse(audio: [], text: "", usage: Usage(), finishReason: "", finishMessage: "", raw: nil)
        }
        var finishReason = ""
        if case let .string(fr)? = first.member("finishReason") { finishReason = fr }

        var audio: [AudioData] = []
        var text = ""
        if case let .array(parts)? = first.lookup("content.parts") {
            for part in parts {
                if let inline = part.member("inlineData"),
                   case let .string(data)? = inline.member("data"), !data.isEmpty,
                   let decoded = Data(base64Encoded: data) {
                    var mime = fallbackMime
                    if case let .string(echoed)? = inline.member("mimeType"), !echoed.isEmpty { mime = echoed }
                    audio.append(AudioData(mimeType: mime, bytes: [UInt8](decoded)))
                }
                if case let .string(t)? = part.member("text"), !t.isEmpty { text += t }
            }
        }
        return MusicResponse(audio: audio, text: text, usage: Usage(), finishReason: finishReason, finishMessage: "", raw: nil)
    }

    /// MiniMax responses. Shape:
    /// `{"data": {"audio": "<hex>"}, "base_resp": {"status_msg": "..."}}`.
    private func parseMinimaxResponse(_ raw: JSONValue, _ fallbackMime: String) -> MusicResponse {
        var audio: [AudioData] = []
        if case let .string(hex)? = raw.lookup("data.audio"), !hex.isEmpty, let decoded = hexDecode(hex) {
            audio.append(AudioData(mimeType: fallbackMime, bytes: decoded))
        }
        var finishMessage = ""
        if case let .string(msg)? = raw.lookup("base_resp.status_msg"), !msg.isEmpty, msg != "success" {
            finishMessage = msg
        }
        return MusicResponse(audio: audio, text: "", usage: Usage(), finishReason: "", finishMessage: finishMessage, raw: nil)
    }

    /// Decode a hex string to bytes. Returns nil on odd length or any non-hex
    /// digit (matching Go's hex.DecodeString error -> no audio). Hand-rolled to
    /// avoid a dependency.
    private func hexDecode(_ s: String) -> [UInt8]? {
        let chars = Array(s.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = hexNibble(chars[i]), let lo = hexNibble(chars[i + 1]) else { return nil }
            out.append((hi << 4) | lo)
            i += 2
        }
        return out
    }

    private func hexNibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30        // 0-9
        case 0x61...0x66: return c - 0x61 + 10   // a-f
        case 0x41...0x46: return c - 0x41 + 10   // A-F
        default: return nil
        }
    }
}

/// The accumulated music-generation parameters carried by the `Music` builder.
/// Internal — the public surface is the builder chain.
struct MusicOptions: Sendable {
    var middleware: [MiddlewareFn] = []
    /// Opt-in: populate `MusicResponse.raw` with the parsed provider body (ADR-014).
    var raw: Bool = false
}
