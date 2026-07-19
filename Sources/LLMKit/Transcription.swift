import Foundation

///
///
///
///
///
///
///
public enum Part: Sendable, Equatable {
    ///
    case text(String)
    ///
    case audio(url: String)
    ///
    case audioData(MediaRef)

    ///
    ///
    public static func audioBytes(mimeType: String, data: Data) -> Part {
        .audioData(MediaRef(mimeType: mimeType, bytes: [UInt8](data)))
    }
}

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
public struct Transcription: Sendable {
    let provider: ProviderName
    let apiKey: String
    let baseURLOverride: String?
    let http: HTTPClient
    var modelOverride: String?

    init(provider: ProviderName, apiKey: String, baseURLOverride: String?, http: HTTPClient) {
        self.provider = provider
        self.apiKey = apiKey
        self.baseURLOverride = baseURLOverride
        self.http = http
    }

    ///
    ///
    public func model(_ model: String) -> Transcription { with { $0.modelOverride = model } }

    //

    ///
    ///
    ///
    ///
    ///
    ///
    public func submit(_ parts: [Part]) async throws -> TranscriptionJob {
        guard !apiKey.isEmpty else {
            throw LLMKitError.validation(field: "api_key", message: "required")
        }
        let config = providerConfig(provider)
        guard let tcCfg = transcriptionConfig(provider) else {
            throw LLMKitError.validation(field: "provider", message: "\(config.slug) does not support transcription")
        }
        //
        //
        if tcCfg.interaction == "sync" {
            throw LLMKitError.validation(
                field: "interaction",
                message: "\(config.slug) transcribes synchronously; use transcribe, not submit"
            )
        }

        let (url, bytes) = try normalizeAudioPart(parts)
        let base = baseURLOverride ?? config.baseURL
        let headers = RequestBuilder.buildAuthHeaders(config: config, apiKey: apiKey)

        //
        //
        let audioURL: String
        if let raw = bytes {
            guard !tcCfg.uploadEndpoint.isEmpty else {
                throw LLMKitError.validation(
                    field: "parts",
                    message: "\(config.slug) does not accept audio bytes; pass a public audio URL"
                )
            }
            let (status, body) = try await http.postBytes(
                url: base + tcCfg.uploadEndpoint, body: Data(raw), headers: headers
            )
            guard (200..<300).contains(status) else {
                throw LLMKitError.api(provider: "transcription_upload", statusCode: status, message: String(decoding: body, as: UTF8.self))
            }
            let up = try JSONValue.parse(String(decoding: body, as: UTF8.self))
            let uploaded = up.stringValue(at: "upload_url")
            guard !uploaded.isEmpty else {
                throw LLMKitError.unsupported("transcription upload: response carried no upload_url")
            }
            audioURL = uploaded
        } else {
            audioURL = url
        }

        var submitHeaders = headers
        submitHeaders.append(("content-type", "application/json"))
        let body = JSONValue.object([("audio_url", .string(audioURL))])
        let (status, responseBody) = try await http.postJSON(
            url: base + tcCfg.submitEndpoint, body: body, headers: submitHeaders
        )
        guard (200..<300).contains(status) else {
            throw LLMKitError.api(provider: "transcription_submit", statusCode: status, message: String(decoding: responseBody, as: UTF8.self))
        }
        let parsed = try JSONValue.parse(String(decoding: responseBody, as: UTF8.self))
        let id = parsed.stringValue(at: tcCfg.submitHandleField)
        guard !id.isEmpty else {
            throw LLMKitError.unsupported("transcription submit: empty handle field \"\(tcCfg.submitHandleField)\"")
        }
        let handle = TranscriptionHandle(id: id, provider: provider)
        return TranscriptionJob(handle: handle, apiKey: apiKey, http: http, baseURLOverride: baseURLOverride)
    }

    //

    ///
    ///
    ///
    ///
    ///
    public func transcribe(_ parts: [Part]) async throws -> TranscriptionResponse {
        guard !apiKey.isEmpty else {
            throw LLMKitError.validation(field: "api_key", message: "required")
        }
        let config = providerConfig(provider)
        guard let tcCfg = transcriptionConfig(provider) else {
            throw LLMKitError.validation(field: "provider", message: "\(config.slug) does not support transcription")
        }
        if tcCfg.interaction != "sync" {
            throw LLMKitError.validation(
                field: "interaction",
                message: "\(config.slug) transcribes asynchronously; use submit, not transcribe"
            )
        }
        guard let model = modelOverride, !model.isEmpty else {
            throw LLMKitError.validation(field: "model", message: "required for synchronous transcription")
        }
        let media = try normalizeAudioBytesPart(parts)

        let base = baseURLOverride ?? config.baseURL
        let headers = RequestBuilder.buildAuthHeaders(config: config, apiKey: apiKey)

        //
        //
        //
        //
        let mime = media.mimeType.isEmpty ? "application/octet-stream" : media.mimeType
        let filename = "audio.\(Self.audioExtForMime(media.mimeType))"
        let (status, body) = try await http.postMultipart(
            url: base + tcCfg.submitEndpoint,
            fields: [("model", model), ("response_format", "verbose_json")],
            file: ("file", filename, mime, Data(media.bytes)),
            headers: headers
        )
        guard (200..<300).contains(status) else {
            throw LLMKitError.api(provider: config.slug, statusCode: status, message: String(decoding: body, as: UTF8.self))
        }
        let raw = try JSONValue.parse(String(decoding: body, as: UTF8.self))
        return Self.resultFromOpenAI(raw)
    }

    ///
    private func with(_ mutate: (inout Transcription) -> Void) -> Transcription {
        var copy = self
        mutate(&copy)
        return copy
    }

    //

    ///
    ///
    private func normalizeAudioPart(_ parts: [Part]) throws -> (url: String, bytes: [UInt8]?) {
        var url = ""
        var bytes: [UInt8]?
        var audioCount = 0
        for part in parts {
            switch part {
            case let .audio(u):
                audioCount += 1
                url = u
            case let .audioData(media):
                audioCount += 1
                bytes = media.bytes
            case .text:
                throw LLMKitError.validation(
                    field: "parts", message: "transcription accepts only audio parts (audio / audio_bytes)"
                )
            }
        }
        guard audioCount == 1 else {
            throw LLMKitError.validation(field: "parts", message: "transcription requires exactly one audio part")
        }
        return (url, bytes)
    }

    ///
    ///
    ///
    private func normalizeAudioBytesPart(_ parts: [Part]) throws -> MediaRef {
        var media: MediaRef?
        var audioCount = 0
        for part in parts {
            switch part {
            case let .audioData(m):
                audioCount += 1
                media = m
            case .audio:
                throw LLMKitError.validation(
                    field: "parts",
                    message: "synchronous transcription accepts inline audio bytes only (audio_bytes); a remote audio URL is not supported"
                )
            case .text:
                throw LLMKitError.validation(
                    field: "parts", message: "transcription accepts only audio parts (audio_bytes)"
                )
            }
        }
        guard let m = media, audioCount == 1 else {
            throw LLMKitError.validation(field: "parts", message: "transcription requires exactly one audio part")
        }
        return m
    }

    //

    ///
    ///
    ///
    ///
    ///
    static func resultFromOpenAI(_ raw: JSONValue) -> TranscriptionResponse {
        let text = raw.stringValue(at: "text")
        var segments: [TranscriptSegment] = []
        if case let .array(items)? = raw.member("segments") {
            for item in items {
                guard case .object = item else { continue }
                let start = Int((item.doubleValue(at: "start") * 1000).rounded())
                let end = Int((item.doubleValue(at: "end") * 1000).rounded())
                segments.append(TranscriptSegment(
                    text: item.stringValue(at: "text"), start: start, end: end, speaker: ""
                ))
            }
        }
        return TranscriptionResponse(text: text, segments: segments, usage: Usage())
    }

    ///
    ///
    ///
    ///
    ///
    static func resultFromAssemblyAI(_ raw: JSONValue) -> TranscriptionResponse {
        let text = raw.stringValue(at: "text")
        var segments: [TranscriptSegment] = []
        if case let .array(words)? = raw.member("words") {
            for word in words {
                guard case .object = word else { continue }
                segments.append(TranscriptSegment(
                    text: word.stringValue(at: "text"),
                    start: word.intValue(at: "start"),
                    end: word.intValue(at: "end"),
                    speaker: word.stringValue(at: "speaker")
                ))
            }
        }
        return TranscriptionResponse(text: text, segments: segments, usage: Usage())
    }

    ///
    ///
    ///
    static func result(_ tcCfg: TranscriptionDef, _ raw: JSONValue) throws -> TranscriptionResponse {
        switch tcCfg.wireShape {
        case "TranscriptionAssemblyAI":
            return resultFromAssemblyAI(raw)
        default:
            throw LLMKitError.unsupported("transcription: unsupported wire shape \"\(tcCfg.wireShape)\"")
        }
    }

    ///
    ///
    static func audioExtForMime(_ mime: String) -> String {
        switch mime {
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/wav", "audio/x-wav": return "wav"
        case "audio/mp4", "audio/m4a", "audio/x-m4a": return "m4a"
        case "audio/webm": return "webm"
        case "audio/ogg", "audio/opus": return "ogg"
        case "audio/flac": return "flac"
        default: return "bin"
        }
    }
}

///
///
///
///
public final class TranscriptionJob: Sendable {
    ///
    public let handle: TranscriptionHandle
    let apiKey: String
    let http: HTTPClient
    let baseURLOverride: String?
    ///
    ///
    let interval: TimeInterval
    let timeout: TimeInterval

    init(
        handle: TranscriptionHandle, apiKey: String, http: HTTPClient, baseURLOverride: String?,
        interval: TimeInterval = 3, timeout: TimeInterval = 600
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
    func cadence(interval: TimeInterval, timeout: TimeInterval) -> TranscriptionJob {
        TranscriptionJob(
            handle: handle, apiKey: apiKey, http: http, baseURLOverride: baseURLOverride,
            interval: interval, timeout: timeout
        )
    }

    ///
    public func poll() async throws -> JobStatus<TranscriptionResponse> {
        try await Job.pollOnce(try makeAdapter())
    }

    ///
    public func wait() async throws -> TranscriptionResponse {
        var adapter = try makeAdapter()
        adapter.lc.pollInterval = interval
        adapter.lc.pollTimeout = timeout
        return try await Job.pollJob(adapter)
    }

    private func makeAdapter() throws -> TranscriptionAdapter {
        try TranscriptionAdapter(
            provider: handle.provider, apiKey: apiKey, http: http,
            baseURLOverride: baseURLOverride, id: handle.id
        )
    }
}

///
///
///
struct TranscriptionAdapter: JobAdapter {
    var lc: LifecycleConfig
    var config: LifecycleConfig { lc }
    let spec: ProviderSpec
    let tcCfg: TranscriptionDef
    let headers: [(String, String)]
    let pollURL: String
    let http: HTTPClient

    init(provider: ProviderName, apiKey: String, http: HTTPClient, baseURLOverride: String?, id: String) throws {
        let config = providerConfig(provider)
        guard let tcCfg = transcriptionConfig(provider) else {
            throw LLMKitError.validation(field: "provider", message: "\(config.slug) does not support transcription")
        }
        let base = baseURLOverride ?? config.baseURL
        let headers = RequestBuilder.buildAuthHeaders(config: config, apiKey: apiKey)
        let pollURL = base + tcCfg.pollEndpoint.replacingOccurrences(of: "{id}", with: id)

        self.spec = config
        self.tcCfg = tcCfg
        self.headers = headers
        self.pollURL = pollURL
        self.http = http
        self.lc = LifecycleConfig(
            noun: "transcription",
            provider: config.slug,
            id: id,
            statusPath: tcCfg.statusPath,
            doneValues: Job.nonEmptyValues([tcCfg.doneStatus]),
            errorValues: Job.nonEmptyValues([tcCfg.errorStatus]),
            errorMessagePath: config.errorMessagePath,
            pollInterval: 3,
            pollTimeout: 600
        )
    }

    func poll() async throws -> PollBody {
        let (status, body) = try await http.getText(url: pollURL, headers: headers)
        guard (200..<300).contains(status) else {
            throw LLMKitError.api(provider: "transcription_poll", statusCode: status, message: String(decoding: body, as: UTF8.self))
        }
        return PollBody(raw: try JSONValue.parse(String(decoding: body, as: UTF8.self)))
    }

    func classify(_ body: PollBody) throws -> Classification {
        Job.classifyByConfig(lc, body)
    }

    func result(_ body: PollBody) async throws -> TranscriptionResponse {
        try Transcription.result(tcCfg, body.value())
    }
}
