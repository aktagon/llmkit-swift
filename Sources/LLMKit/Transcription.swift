import Foundation

/// The shared multimodal input atom (the API golden rule: single-turn
/// capabilities take `[Part]`, not `[Message]`). Slice 1 carries only the
/// variants transcription needs — text plus the two audio sources — mirroring
/// Rust's `Part::audio` / `Part::audio_bytes`. `audio(url:)` is a remote URL
/// (AssemblyAI ingests a public URL); `audioBytes(mimeType:data:)` is inline
/// bytes (OpenAI multipart ingests raw bytes). More modalities join as later
/// capabilities land on the `[Part]` container.
public enum Part: Sendable, Equatable {
    /// Plain text input.
    case text(String)
    /// A remote audio URL (AssemblyAI).
    case audio(url: String)
    /// Inline audio bytes (OpenAI multipart). Carries the IANA mime + raw bytes.
    case audioData(MediaRef)

    /// Inline audio bytes from a mime type + `Data`. Mirror of Rust
    /// `Part::audio_bytes`.
    public static func audioBytes(mimeType: String, data: Data) -> Part {
        .audioData(MediaRef(mimeType: mimeType, bytes: [UInt8](data)))
    }
}

/// Transcription (speech-to-text) runtime (ADR-048 / ADR-051) — a port of Rust's
/// `builders/transcription.rs` onto the shared Job engine (ADR-062). One
/// capability, two execution shapes selected by the generated
/// `transcriptionConfig(provider).interaction` fact (never the provider name):
///
/// - `submit([Part])` — ASYNCHRONOUS (AssemblyAI): POST a `{audio_url}` JSON body
///   (optionally preceded by an upload hop for inline bytes), returning a live
///   `TranscriptionJob` immediately; poll it to completion with `wait` / `poll`.
/// - `transcribe([Part])` — SYNCHRONOUS (OpenAI, ADR-051): a single
///   `multipart/form-data` POST returns the transcript directly, no job handle.
///   This is the first multipart request path in the Swift SDK.
///
/// The result decode is wire-shape-keyed (STT-005); the submit / poll / status
/// endpoints and the sync-vs-async split are config. `TranscriptionResponse` is
/// text-shaped, NOT a media `*Data` container — the structural divergence from
/// video (ADR-048).
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

    /// Select the transcription model (required by the synchronous path; the
    /// asynchronous provider infers it).
    public func model(_ model: String) -> Transcription { with { $0.modelOverride = model } }

    // MARK: - Async submit (AssemblyAI)

    /// Submit an asynchronous speech-to-text job and return the live
    /// `TranscriptionJob`. Pre-flight rejects a synchronous provider (naming
    /// `transcribe`) and anything other than exactly one audio Part before any
    /// HTTP call (STT-003). For an audio-bytes part the runtime performs the
    /// upload hop (POST the raw bytes, read `upload_url`) before submitting
    /// (STT-005).
    public func submit(_ parts: [Part]) async throws -> TranscriptionJob {
        guard !apiKey.isEmpty else {
            throw LLMKitError.validation(field: "api_key", message: "required")
        }
        let config = providerConfig(provider)
        guard let tcCfg = transcriptionConfig(provider) else {
            throw LLMKitError.validation(field: "provider", message: "\(config.slug) does not support transcription")
        }
        // A synchronous provider has no job handle; Submit/Wait is the wrong
        // terminal for it (ADR-051 OAA-003). Name the supported one.
        if tcCfg.interaction == "sync" {
            throw LLMKitError.validation(
                field: "interaction",
                message: "\(config.slug) transcribes synchronously; use transcribe, not submit"
            )
        }

        let (url, bytes) = try normalizeAudioPart(parts)
        let base = baseURLOverride ?? config.baseURL
        let headers = RequestBuilder.buildAuthHeaders(config: config, apiKey: apiKey)

        // Upload hop (STT-005): a bytes part is uploaded first to obtain a URL the
        // submit body can reference. URL parts skip this entirely.
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

    // MARK: - Sync transcribe (OpenAI)

    /// Run a SYNCHRONOUS speech-to-text request (ADR-051): one
    /// `multipart/form-data` POST returns the transcript directly, no job handle.
    /// Pre-flight rejects a non-sync provider (naming submit), a missing model, a
    /// remote audio URL (OpenAI ingests inline bytes only — the inverse of
    /// AssemblyAI, OAA-005), and a non-single-audio-bytes input.
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

        // Build the multipart body in FIXED field order (model, response_format,
        // file) so all four SDKs emit the same canonical descriptor (ADR-051
        // OQ-3). The file part carries the real audio mime + the format-detecting
        // extension.
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

    /// Clone-on-chain helper: copy, mutate, return.
    private func with(_ mutate: (inout Transcription) -> Void) -> Transcription {
        var copy = self
        mutate(&copy)
        return copy
    }

    // MARK: - Part normalization (pre-flight, before any HTTP call)

    /// Enforces the single-audio-part rule (STT-003) and returns the audio source:
    /// a URL XOR raw bytes. Mirror of `normalize_audio_part`.
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

    /// Enforces the single-audio-bytes rule for the sync path (OAA-005): exactly
    /// one inline-bytes audio Part. A remote URL is rejected (OpenAI ingests no
    /// URL — the inverse of AssemblyAI). Mirror of `normalize_audio_bytes_part`.
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

    // MARK: - Result decode (wire-shape-keyed, STT-005)

    /// Extracts the transcript text + (when present) segment timings from a
    /// synchronous OpenAI response. verbose_json offsets are SECONDS (float) ->
    /// integer milliseconds (x1000, rounded, OAA-006). Missing segments -> empty,
    /// not an error. Usage stays zero (OAA-007). Mirror of
    /// `transcription_result_from_openai`.
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

    /// Extracts the transcript text + word-level timing from a completed
    /// AssemblyAI transcript object. start/end are integer milliseconds; speaker
    /// is present only on diarized transcripts. Usage stays zero — AssemblyAI
    /// bills by audio duration, not tokens (ADR-048 OQ-2). Mirror of
    /// `transcription_result_from_assemblyai`.
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

    /// Extracts the finished transcript per wire shape. Only the result decode is
    /// wire-shape-keyed (STT-005); the submit / poll / status facts are config.
    /// Mirror of `transcription_result`.
    static func result(_ tcCfg: TranscriptionDef, _ raw: JSONValue) throws -> TranscriptionResponse {
        switch tcCfg.wireShape {
        case "TranscriptionAssemblyAI":
            return resultFromAssemblyAI(raw)
        default:
            throw LLMKitError.unsupported("transcription: unsupported wire shape \"\(tcCfg.wireShape)\"")
        }
    }

    /// Maps an audio IANA media type to the file extension OpenAI uses to detect
    /// the format. Mirror of `audio_ext_for_mime`.
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

/// The live transcription handle: the persistable `TranscriptionHandle` value
/// plus the credentials + transport needed to poll it (mirror of `VideoJob` /
/// `BatchJob`). `handle` is the persistable value for cross-process resume
/// (ADR-014).
public final class TranscriptionJob: Sendable {
    /// The persistable identity value (ADR-014 cross-process resume).
    public let handle: TranscriptionHandle
    let apiKey: String
    let http: HTTPClient
    let baseURLOverride: String?
    /// Poll cadence for `wait` (tests shrink these via `cadence`; defaults match
    /// Rust/Go — 3s interval, 10min timeout).
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

    /// A copy with the same identity + transport and the given poll cadence
    /// (internal test seam).
    func cadence(interval: TimeInterval, timeout: TimeInterval) -> TranscriptionJob {
        TranscriptionJob(
            handle: handle, apiKey: apiKey, http: http, baseURLOverride: baseURLOverride,
            interval: interval, timeout: timeout
        )
    }

    /// One normalized poll round-trip (ADR-063 POLL-001): no loop.
    public func poll() async throws -> JobStatus<TranscriptionResponse> {
        try await Job.pollOnce(try makeAdapter())
    }

    /// Poll until a terminal state, returning the finished `TranscriptionResponse`.
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

/// Binds async transcription to the Job engine's four seams (ADR-062). `classify`
/// uses the config-backed default (status vs done_status / error_status);
/// `result` decodes the finished transcript per wire shape (no second hop).
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
