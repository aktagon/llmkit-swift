import Foundation

/// Speech-generation (text-to-speech) runtime — a port of Rust's `speech.rs`
/// (ADR-049 / ADR-051). Synchronous: `client.speech.<config>.generate(text)`
/// builds the provider request body, sends it once, and parses the reply into
/// the universal `SpeechResponse` (a single `AudioData` clip, ADR-049 OQ-4).
///
/// The generated `speechGenConfig(provider)` fact selects both the request body
/// (`wireShape`) and the audio decode (`audioResponseEncoding`) — never the
/// provider name. Five shapes ship: `SpeechInworld` (a flat-JSON POST whose reply
/// carries base64 audio at `audioContent`), `SpeechOpenAI` (a flat-JSON POST
/// whose reply is RAW audio bytes — never JSON, so the response is read as bytes
/// and taken verbatim), `SpeechGemini` (Interactions API, base64 audio in
/// `steps[]`), `SpeechMiniMax` (hex audio at `data.audio`) and `SpeechXAI` (a
/// flat-JSON POST whose reply is RAW audio bytes). Pre-flight validation (model + text or lines required;
/// voice or speakers; provider supports speech; model known; speakers and
/// style the model takes, BUG-091) runs before any HTTP call. Voices are
/// free-form: there is no catalogue. Fires the `speechGeneration` middleware
/// op around the request (BUG-036).
public struct Speech: Sendable {
    let provider: ProviderName
    let apiKey: String
    let baseURLOverride: String?
    let http: HTTPClient
    var modelOverride: String?
    var voiceOverride: String?
    var style: String = ""
    var speakers: [(name: String, voice: String)] = []
    var lines: [(speaker: String, style: String, text: String)] = []
    var middleware: [MiddlewareFn] = []

    init(provider: ProviderName, apiKey: String, baseURLOverride: String?, http: HTTPClient) {
        self.provider = provider
        self.apiKey = apiKey
        self.baseURLOverride = baseURLOverride
        self.http = http
    }

    /// Select the speech-generation model (required).
    public func model(_ model: String) -> Speech { with { $0.modelOverride = model } }

    /// Select the voice — a free-form voice id, sent as given (SPK-004; no
    /// catalogue since 2026-10-15).
    public func voice(_ voice: String) -> Speech { with { $0.voiceOverride = voice } }

    /// Sets the delivery style for a single-voice speech request, such as
    /// "cheerful". A model that does not take a style rejects it before send.
    public func style(_ style: String) -> Speech { with { $0.style = style } }

    /// Declares a named speaker and its voice for a multi-speaker speech
    /// request. Declare exactly 2 speakers, and do not set a voice with them.
    public func addSpeaker(_ name: String, _ voice: String) -> Speech {
        with { $0.speakers.append((name: name, voice: voice)) }
    }

    /// Appends a line said by a declared speaker. Lines are spoken in call
    /// order. When lines are set, the text passed to generate must be empty.
    public func addLine(_ speaker: String, _ text: String) -> Speech {
        with { $0.lines.append((speaker: speaker, style: "", text: text)) }
    }

    /// Appends a line said by a declared speaker in a delivery style, such as
    /// "calm and relaxed". Otherwise it works like addLine.
    public func addStyledLine(_ speaker: String, _ style: String, _ text: String) -> Speech {
        with { $0.lines.append((speaker: speaker, style: style, text: text)) }
    }

    /// Register a middleware hook (observation + pre-phase veto).
    public func addMiddleware(_ hook: @escaping MiddlewareFn) -> Speech {
        with { $0.middleware.append(hook) }
    }

    /// Synthesize speech audio from `text`. Builds the provider body, sends it
    /// once, and decodes the reply per the wire shape's audio encoding. Fires
    /// the `speechGeneration` middleware op pre + post around the request
    /// (pre-phase veto, post-phase observation).
    public func generate(_ text: String) async throws -> SpeechResponse {
        guard !apiKey.isEmpty else {
            throw LLMKitError.validation(field: "api_key", message: "required")
        }
        guard let model = modelOverride, !model.isEmpty else {
            throw LLMKitError.validation(field: "model", message: "required for speech generation")
        }
        let voice = voiceOverride ?? ""
        try validateInputs(voice: voice, text: text)

        let config = providerConfig(provider)
        guard let sgCfg = speechGenConfig(provider) else {
            throw LLMKitError.validation(field: "provider", message: "\(config.slug) does not support speech generation")
        }
        guard let modelDef = sgCfg.models.first(where: { $0.modelId == model }) else {
            throw LLMKitError.validation(
                field: "model", message: "\(model) is not a known speech-generation model for \(config.slug)"
            )
        }
        try validateModel(modelDef)

        let baseEvent = Event(op: .speechGeneration, provider: provider.rawValue, model: model)
        let start = Date()
        try Middleware.firePre(middleware, baseEvent)

        var postEvent = baseEvent
        do {
            var headers = RequestBuilder.buildAuthHeaders(config: config, apiKey: apiKey)
            headers.append(("content-type", "application/json"))

            let endpoint = sgCfg.genEndpoint.isEmpty ? config.endpoint : sgCfg.genEndpoint
            // buildURL appends the QueryParamKey `?key=` for Google, as on every
            // other Google call. Speech base: explicit override > the config's
            // distinct speech base (MiniMax, HANDOFF-094) > chat base.
            let speechBase = baseURLOverride ?? (sgCfg.baseURL.isEmpty ? nil : sgCfg.baseURL)
            let url = endpoint.hasPrefix("http")
                ? endpoint
                : RequestBuilder.buildURL(
                    config: config, endpoint: endpoint, apiKey: apiKey, model: model, baseURLOverride: speechBase
                )

            let body = try requestBody(sgCfg, model: model, voice: voice, text: text)

            // The OpenAI shape returns binary audio (not JSON), so the reply is
            // read as raw bytes and must not be lossily UTF-8 decoded before the
            // fork.
            let (statusCode, data) = try await http.postJSON(url: url, body: body, headers: headers)
            guard (200..<300).contains(statusCode) else {
                throw ResponseParser.parseError(config: config, statusCode: statusCode, body: data)
            }
            let response = try parseResponse(
                provider: config.slug,
                encoding: sgCfg.audioResponseEncoding,
                fallbackMime: modelDef.outputMime,
                body: data
            )
            postEvent.duration = Date().timeIntervalSince(start)
            postEvent.usage = response.usage
            Middleware.firePost(middleware, postEvent)
            return response
        } catch {
            postEvent.duration = Date().timeIntervalSince(start)
            Middleware.setError(&postEvent, error)
            Middleware.firePost(middleware, postEvent)
            throw error
        }
    }

    /// Checks the request on its own, before the provider config is read
    /// (BUG-091). The messages are the same in every SDK.
    private func validateInputs(voice: String, text: String) throws {
        if lines.isEmpty && text.isEmpty {
            throw LLMKitError.validation(field: "text", message: "required for speech generation")
        }
        if !lines.isEmpty && !text.isEmpty {
            throw LLMKitError.validation(field: "text", message: "must be empty when lines are set")
        }
        if speakers.isEmpty {
            if voice.isEmpty {
                throw LLMKitError.validation(field: "voice", message: "required for speech generation")
            }
        } else {
            if !voice.isEmpty {
                throw LLMKitError.validation(field: "voice", message: "cannot be set together with speakers")
            }
            if !style.isEmpty {
                throw LLMKitError.validation(
                    field: "style", message: "cannot be set together with speakers; style each line instead")
            }
            if lines.isEmpty {
                throw LLMKitError.validation(field: "lines", message: "required when speakers are set")
            }
        }
        for line in lines where !speakers.contains(where: { $0.name == line.speaker }) {
            throw LLMKitError.validation(field: "lines", message: "\(line.speaker) is not a declared speaker")
        }
    }

    /// Checks the request against the model's speaker and style facts (BUG-091).
    private func validateModel(_ model: SpeechModelDef) throws {
        if !speakers.isEmpty {
            if model.maxSpeakers == 0 {
                throw LLMKitError.validation(
                    field: "speakers", message: "\(model.modelId) does not support multiple speakers")
            }
            if speakers.count != model.maxSpeakers {
                throw LLMKitError.validation(
                    field: "speakers",
                    message: "exactly \(model.maxSpeakers) speakers are required, got \(speakers.count)")
            }
        }
        let styled = !style.isEmpty || lines.contains(where: { !$0.style.isEmpty })
        if styled && !model.supportsSpeechStyle {
            throw LLMKitError.validation(field: "style", message: "\(model.modelId) does not support a speech style")
        }
    }

    /// Clone-on-chain helper: copy, mutate, return.
    private func with(_ mutate: (inout Speech) -> Void) -> Speech {
        var copy = self
        mutate(&copy)
        return copy
    }

    // MARK: - Request bodies

    /// Selects the request body by the config's wire shape (BUG-105).
    func requestBody(_ sgCfg: SpeechGenDef, model: String, voice: String, text: String) throws -> JSONValue {
        switch sgCfg.wireShape {
        case "SpeechInworld":
            return buildInworldBody(model: model, voice: voice, text: text, format: sgCfg.requestedOutputFormat)
        case "SpeechOpenAI":
            return buildOpenAIBody(
                model: model, voice: voice, text: text, style: style, format: sgCfg.requestedOutputFormat)
        case "SpeechGemini": return buildGeminiBody(model: model, voice: voice, text: text)
        case "SpeechMiniMax": return buildMiniMaxBody(model: model, voice: voice, text: text)
        case "SpeechXAI": return buildXAIBody(voice: voice, text: text, format: sgCfg.requestedOutputFormat)
        default:
            throw LLMKitError.unsupported("speech: unsupported wire shape \"\(sgCfg.wireShape)\"")
        }
    }

    /// Inworld `/tts/v1/voice` body. Sends the config's requested format
    /// (LINEAR16) at a fixed 22050 Hz and BALANCED delivery; sample-rate
    /// selection is a later slice (ADR-049 OQ-5).
    private func buildInworldBody(model: String, voice: String, text: String, format: String) -> JSONValue {
        .object([
            ("text", .string(text)),
            ("voiceId", .string(voice)),
            ("modelId", .string(model)),
            ("audioConfig", .object([
                ("audioEncoding", .string(format)),
                ("sampleRateHertz", .int(22050)),
            ])),
            ("deliveryMode", .string("BALANCED")),
        ])
    }

    /// OpenAI `/v1/audio/speech` body. response_format is the config's
    /// requested format (mp3). A style is sent as `instructions` (BUG-091),
    /// which gpt-4o-mini-tts accepts.
    private func buildOpenAIBody(
        model: String, voice: String, text: String, style: String, format: String
    ) -> JSONValue {
        var fields: [(String, JSONValue)] = [
            ("model", .string(model)),
            ("input", .string(text)),
            ("voice", .string(voice)),
            ("response_format", .string(format)),
        ]
        if !style.isEmpty { fields.append(("instructions", .string(style))) }
        return .object(fields)
    }

    /// MiniMax /v1/t2a_v2 body (HANDOFF-094): only the fields the reference
    /// marks required. stream, output_format (hex) and audio_setting (mp3)
    /// take their defaults.
    private func buildMiniMaxBody(model: String, voice: String, text: String) -> JSONValue {
        .object([
            ("model", .string(model)),
            ("text", .string(text)),
            ("voice_setting", .object([("voice_id", .string(voice))])),
        ])
    }

    /// xAI /v1/tts body (HANDOFF-095). The endpoint has no model field.
    /// language is always "auto" (llmkit has no language option), and
    /// with_timestamps is never sent: it switches the reply from raw audio
    /// bytes to JSON.
    private func buildXAIBody(voice: String, text: String, format: String) -> JSONValue {
        .object([
            ("text", .string(text)),
            ("voice_id", .string(voice)),
            ("language", .string("auto")),
            ("output_format", .object([("codec", .string(format))])),
        ])
    }

    /// Gemini TTS body on the Interactions API (BUG-091): one user_input turn
    /// and an audio response. Single voice: one text item and
    /// `speech_config [{voice}]`; a style annotates the text item.
    /// Multi-speaker: one text item per line, each annotated with its speaker
    /// and optional style, and `speech_config {speakers}`. `store` is always
    /// false: the Interactions API keeps requests by default.
    private func buildGeminiBody(model: String, voice: String, text: String) -> JSONValue {
        var content: [JSONValue] = []
        let speechConfig: JSONValue
        if speakers.isEmpty {
            var item: [(String, JSONValue)] = [("type", .string("text")), ("text", .string(text))]
            if !style.isEmpty {
                item.append(("annotations", .array([.object([
                    ("type", .string("speech_metadata")), ("style", .string(style)),
                ])])))
            }
            content.append(.object(item))
            speechConfig = .array([.object([("voice", .string(voice))])])
        } else {
            for line in lines {
                var meta: [(String, JSONValue)] = [
                    ("type", .string("speech_metadata")), ("speaker", .string(line.speaker)),
                ]
                if !line.style.isEmpty { meta.append(("style", .string(line.style))) }
                content.append(.object([
                    ("type", .string("text")), ("text", .string(line.text)),
                    ("annotations", .array([.object(meta)])),
                ]))
            }
            speechConfig = .object([("speakers", .array(speakers.map {
                .object([("speaker", .string($0.name)), ("voice", .string($0.voice))])
            }))])
        }
        return .object([
            ("model", .string(model)),
            ("input", .array([.object([
                ("type", .string("user_input")),
                ("content", .array(content)),
            ])])),
            ("response_format", .object([("type", .string("audio"))])),
            ("generation_config", .object([("speech_config", speechConfig)])),
            ("store", .bool(false)),
        ])
    }

    // MARK: - Response parsing (selected by audioResponseEncoding, never provider name)

    /// Decode the synthesized audio per the wire shape's audio response encoding
    /// (ADR-051 OAA-002). `rawBody` (OpenAI, xAI) takes the response body verbatim as
    /// the audio bytes; `base64Envelope` (Inworld) parses a JSON envelope and
    /// base64-decodes the `audioContent` field; `hexEnvelope` (MiniMax)
    /// hex-decodes `data.audio` and raises on a nonzero `base_resp`. A 2xx body that does not parse
    /// to audio is a decoding error (HANDOFF-036 A5) — never a silent empty
    /// clip.
    func parseResponse(
        provider: String, encoding: String, fallbackMime: String, body: Data
    ) throws -> SpeechResponse {
        var bytes: [UInt8] = []
        var mime = fallbackMime
        if encoding == "rawBody" {
            bytes = [UInt8](body)
        } else if encoding == "base64InteractionSteps" {
            (bytes, mime) = try parseInteractionSteps(provider: provider, fallbackMime: fallbackMime, body: body)
        } else if encoding == "hexEnvelope" {
            bytes = try parseHexEnvelope(provider: provider, body: body)
        } else if encoding == "base64Envelope" {
            let raw: JSONValue
            do {
                raw = try JSONValue.parse(String(decoding: body, as: UTF8.self))
            } catch {
                throw LLMKitError.decoding("\(provider) speech response: not valid JSON: \(error)")
            }
            guard case let .string(b64)? = raw.member("audioContent"), !b64.isEmpty else {
                throw LLMKitError.decoding("\(provider) speech response: missing or empty audioContent")
            }
            guard let decoded = Data(base64Encoded: b64) else {
                throw LLMKitError.decoding("\(provider) speech response: invalid base64 in audioContent")
            }
            bytes = [UInt8](decoded)
        } else {
            throw LLMKitError.unsupported("speech: unsupported audio encoding \"\(encoding)\"")
        }
        return SpeechResponse(
            audio: AudioData(mimeType: mime, bytes: bytes),
            usage: Usage(),
            finishReason: nil
        )
    }

    /// Decode a MiniMax t2a_v2 reply (HANDOFF-094):
    /// `{"data": {"audio": "<hex>"}, "base_resp": {"status_code", "status_msg"}}`.
    /// MiniMax reports failures in `base_resp` on an HTTP 200, so a nonzero
    /// `status_code` is an API error carrying `status_msg`. A success with
    /// missing audio, or invalid hex, is a decoding error (HANDOFF-036 A5).
    private func parseHexEnvelope(provider: String, body: Data) throws -> [UInt8] {
        let raw: JSONValue
        do {
            raw = try JSONValue.parse(String(decoding: body, as: UTF8.self))
        } catch {
            throw LLMKitError.decoding("\(provider) speech response: not valid JSON: \(error)")
        }
        if case let .int(code)? = raw.lookup("base_resp.status_code"), code != 0 {
            var msg = ""
            if case let .string(m)? = raw.lookup("base_resp.status_msg") { msg = m }
            throw LLMKitError.api(
                provider: provider, statusCode: 200, message: "\(msg) (base_resp.status_code \(code))")
        }
        guard case let .string(hex)? = raw.lookup("data.audio"), !hex.isEmpty else {
            throw LLMKitError.decoding("\(provider) speech response: missing or empty data.audio")
        }
        guard let decoded = Music.hexDecode(hex) else {
            throw LLMKitError.decoding("\(provider) speech response: invalid hex in data.audio")
        }
        return decoded
    }

    /// Decode a Gemini TTS Interactions API reply (BUG-091). Google's documented
    /// path is
    /// `[.steps[] | select(.type=="model_output") | .content[] | select(.type=="audio")] | last | .data`:
    /// the LAST audio item across the model_output steps wins. Its `mime_type`
    /// is used when present, else the model's outputMime. No audio item, or
    /// invalid base64, is a decoding error (HANDOFF-036 A5).
    private func parseInteractionSteps(
        provider: String, fallbackMime: String, body: Data
    ) throws -> ([UInt8], String) {
        let raw: JSONValue
        do {
            raw = try JSONValue.parse(String(decoding: body, as: UTF8.self))
        } catch {
            throw LLMKitError.decoding("\(provider) speech response: not valid JSON: \(error)")
        }
        var last: JSONValue?
        if case let .array(steps)? = raw.member("steps") {
            for step in steps {
                guard case .string("model_output")? = step.member("type"),
                      case let .array(content)? = step.member("content") else { continue }
                for item in content {
                    if case .string("audio")? = item.member("type") { last = item }
                }
            }
        }
        guard case let .string(b64)? = last?.member("data"), !b64.isEmpty else {
            throw LLMKitError.decoding("\(provider) speech response: no audio item in steps[model_output].content")
        }
        guard let decoded = Data(base64Encoded: b64) else {
            throw LLMKitError.decoding("\(provider) speech response: invalid base64 in audio data")
        }
        var mime = fallbackMime
        if case let .string(m)? = last?.member("mime_type"), !m.isEmpty { mime = m }
        return ([UInt8](decoded), mime)
    }
}
