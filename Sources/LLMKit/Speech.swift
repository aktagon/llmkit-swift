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

    ///
    public func model(_ model: String) -> Speech { with { $0.modelOverride = model } }

    ///
    ///
    public func voice(_ voice: String) -> Speech { with { $0.voiceOverride = voice } }

    ///
    ///
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

        //
        //
        let (statusCode, data) = try await http.postJSON(url: url, body: body, headers: headers)
        guard (200..<300).contains(statusCode) else {
            throw ResponseParser.parseError(config: config, statusCode: statusCode, body: data)
        }
        return try parseResponse(
            provider: config.slug,
            encoding: sgCfg.audioResponseEncoding,
            fallbackMime: modelDef.outputMime,
            body: data
        )
    }

    ///
    private func with(_ mutate: (inout Speech) -> Void) -> Speech {
        var copy = self
        mutate(&copy)
        return copy
    }

    //

    ///
    ///
    ///
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

    ///
    ///
    private func buildOpenAIBody(model: String, voice: String, text: String) -> JSONValue {
        .object([
            ("model", .string(model)),
            ("input", .string(text)),
            ("voice", .string(voice)),
            ("response_format", .string("mp3")),
        ])
    }

    //

    ///
    ///
    ///
    ///
    ///
    ///
    private func parseResponse(
        provider: String, encoding: String, fallbackMime: String, body: Data
    ) throws -> SpeechResponse {
        var bytes: [UInt8] = []
        if encoding == "rawBody" {
            bytes = [UInt8](body)
        } else {
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
        }
        return SpeechResponse(
            audio: AudioData(mimeType: fallbackMime, bytes: bytes),
            usage: Usage(),
            finishReason: ""
        )
    }
}
