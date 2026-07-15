import Foundation

/// Speech-generation (text-to-speech) runtime — a port of Rust's `speech.rs`
/// (ADR-049 / ADR-051). Synchronous: `client.speech.<config>.generate(text)`
/// builds the provider request body, sends it once, and parses the reply into
/// the universal `SpeechResponse` (a single `AudioData` clip, ADR-049 OQ-4).
///
/// The generated `speechGenConfig(provider)` fact selects both the request body
/// (`wireShape`) and the audio decode (`audioResponseEncoding`) — never the
/// provider name. Two shapes ship: `SpeechInworld` (a flat-JSON POST whose reply
/// carries base64 audio at `audioContent`) and `SpeechOpenAI` (a flat-JSON POST
/// whose reply is RAW audio bytes — never JSON, so the response is read as bytes
/// and taken verbatim). Pre-flight validation (model + text + voice required;
/// provider supports speech; model + voice in catalogue) runs before any HTTP
/// call. No middleware (mirrors the Rust runtime).
public struct Speech: Sendable {
    let provider: ProviderName
    let apiKey: String
    let baseURLOverride: String?
    let http: HTTPClient
    var modelOverride: String?
    var voiceOverride: String?

    init(provider: ProviderName, apiKey: String, baseURLOverride: String?, http: HTTPClient) {
        self.provider = provider
        self.apiKey = apiKey
        self.baseURLOverride = baseURLOverride
        self.http = http
    }

    /// Select the speech-generation model (required).
    public func model(_ model: String) -> Speech { with { $0.modelOverride = model } }

    /// Select the voice — request-data selector validated pre-flight against the
    /// provider's catalogue (SPK-004).
    public func voice(_ voice: String) -> Speech { with { $0.voiceOverride = voice } }

    /// Synthesize speech audio from `text`. Builds the provider body, sends it
    /// once, and decodes the reply per the wire shape's audio encoding.
    public func generate(_ text: String) async throws -> SpeechResponse {
        guard !apiKey.isEmpty else {
            throw LLMKitError.validation(field: "api_key", message: "required")
        }
        guard let model = modelOverride, !model.isEmpty else {
            throw LLMKitError.validation(field: "model", message: "required for speech generation")
        }
        guard !text.isEmpty else {
            throw LLMKitError.validation(field: "text", message: "required for speech generation")
        }
        guard let voice = voiceOverride, !voice.isEmpty else {
            throw LLMKitError.validation(field: "voice", message: "required for speech generation")
        }

        let config = providerConfig(provider)
        guard let sgCfg = speechGenConfig(provider) else {
            throw LLMKitError.validation(field: "provider", message: "\(config.slug) does not support speech generation")
        }
        guard let modelDef = sgCfg.models.first(where: { $0.modelId == model }) else {
            throw LLMKitError.validation(
                field: "model", message: "\(model) is not a known speech-generation model for \(config.slug)"
            )
        }
        guard sgCfg.voices.contains(voice) else {
            throw LLMKitError.validation(field: "voice", message: "\(voice) is not a known voice for \(config.slug)")
        }

        var headers = RequestBuilder.buildAuthHeaders(config: config, apiKey: apiKey)
        headers.append(("content-type", "application/json"))

        let base = baseURLOverride ?? config.baseURL
        let endpoint = sgCfg.genEndpoint.isEmpty ? config.endpoint : sgCfg.genEndpoint
        let url = endpoint.hasPrefix("http") ? endpoint : base + endpoint

        let body = sgCfg.wireShape == "SpeechOpenAI"
            ? buildOpenAIBody(model: model, voice: voice, text: text)
            : buildInworldBody(model: model, voice: voice, text: text)

        // The OpenAI shape returns binary audio (not JSON), so the reply is read
        // as raw bytes and must not be lossily UTF-8 decoded before the fork.
        let (statusCode, data) = try await http.postJSON(url: url, body: body, headers: headers)
        guard (200..<300).contains(statusCode) else {
            throw ResponseParser.parseError(config: config, statusCode: statusCode, body: data)
        }
        return parseResponse(encoding: sgCfg.audioResponseEncoding, fallbackMime: modelDef.outputMime, body: data)
    }

    /// Clone-on-chain helper: copy, mutate, return.
    private func with(_ mutate: (inout Speech) -> Void) -> Speech {
        var copy = self
        mutate(&copy)
        return copy
    }

    // MARK: - Request bodies

    /// Inworld `/tts/v1/voice` body. Slice 1 sends a fixed audioConfig
    /// (LINEAR16/22050 -> WAV) and BALANCED delivery; format/sample-rate selection
    /// is a later slice (ADR-049 OQ-5).
    private func buildInworldBody(model: String, voice: String, text: String) -> JSONValue {
        .object([
            ("text", .string(text)),
            ("voiceId", .string(voice)),
            ("modelId", .string(model)),
            ("audioConfig", .object([
                ("audioEncoding", .string("LINEAR16")),
                ("sampleRateHertz", .int(22050)),
            ])),
            ("deliveryMode", .string("BALANCED")),
        ])
    }

    /// OpenAI `/v1/audio/speech` body. Slice 1 fixes response_format=mp3 (KISS);
    /// format selection is a later slice (ADR-051).
    private func buildOpenAIBody(model: String, voice: String, text: String) -> JSONValue {
        .object([
            ("model", .string(model)),
            ("input", .string(text)),
            ("voice", .string(voice)),
            ("response_format", .string("mp3")),
        ])
    }

    // MARK: - Response parsing (selected by audioResponseEncoding, never provider name)

    /// Decode the synthesized audio per the wire shape's audio response encoding
    /// (ADR-051 OAA-002). `rawBody` (OpenAI) takes the response body verbatim as
    /// the audio bytes; `base64Envelope` (Inworld) parses a JSON envelope and
    /// base64-decodes the `audioContent` field.
    private func parseResponse(encoding: String, fallbackMime: String, body: Data) -> SpeechResponse {
        var bytes: [UInt8] = []
        if encoding == "rawBody" {
            bytes = [UInt8](body)
        } else if let raw = try? JSONValue.parse(String(decoding: body, as: UTF8.self)),
                  case let .string(b64)? = raw.member("audioContent"), !b64.isEmpty,
                  let decoded = Data(base64Encoded: b64) {
            bytes = [UInt8](decoded)
        }
        return SpeechResponse(
            audio: AudioData(mimeType: fallbackMime, bytes: bytes),
            usage: Usage(),
            finishReason: ""
        )
    }
}
