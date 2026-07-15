import Foundation

/// Binds the video capability to the Job engine's four seams (ADR-062). Video's
/// poll classification is NOT config-driven the way batch's is — the generated
/// `VideoGenDef` carries no status paths — so `classify` dispatches on the
/// `wireShape` fact (the port of Rust's `parse_video_poll`) and `result` extracts
/// the finished video URL/bytes per shape (the `video_result_from_*` family,
/// including the MiniMax two-hop file retrieve and the Veo download hop).
struct VideoAdapter: JobAdapter {
    var lc: LifecycleConfig
    var config: LifecycleConfig { lc }
    let providerName: ProviderName
    let spec: ProviderSpec
    let vgCfg: VideoGenDef
    let base: String
    let headers: [(String, String)]
    let handleModel: String
    let raw: Bool
    let http: HTTPClient
    let apiKey: String
    /// Poll transport arm, selected once before the loop (mirror of `wait_video`).
    private enum PollArm {
        case sigv4          // Bedrock: SigV4-signed GET, ARN as one path segment
        case vertexPost     // Vertex Veo: POST {model}:fetchPredictOperation
        case get            // every other provider: verbatim {id} GET
    }
    private let arm: PollArm
    private let pollURL: String

    init(
        provider: ProviderName, apiKey: String, http: HTTPClient, baseURLOverride: String?,
        id: String, model: String, raw: Bool
    ) throws {
        let config = providerConfig(provider)
        guard let vgCfg = videoGenConfig(provider) else {
            throw LLMKitError.validation(field: "provider", message: "\(config.slug) does not support video generation")
        }
        let base = VideoWire.baseURL(config: config, vgCfg: vgCfg, override: baseURLOverride)
        var headers = RequestBuilder.buildAuthHeaders(config: config, apiKey: apiKey)
        // PixVerse requires the per-request Ai-trace-id on the poll GET too; one
        // per wait call suffices (uniqueness is an anti-cache measure on submit).
        if vgCfg.wireShape == "VideoPixVerse" {
            headers.append(("Ai-trace-id", Video.newTraceID()))
        }

        // The arms are config-disjoint: SigV4 keys off authScheme, vertexPost off
        // wireShape, and no A-Box pairs SigV4 with VideoVertexVeo. SigV4 is matched
        // first so a hypothetical both-true misconfig polls as SigV4.
        let arm: PollArm
        let pollURL: String
        if config.authScheme == "SigV4" {
            arm = .sigv4
            // Encode the ARN's '/' to %2F (one path segment) but leave ':' literal
            // (Bedrock's SigV4 canonicalization accepts a literal ':').
            pollURL = base + vgCfg.pollEndpoint.replacingOccurrences(
                of: "{id}", with: id.replacingOccurrences(of: "/", with: "%2F")
            )
        } else if vgCfg.wireShape == "VideoVertexVeo" {
            arm = .vertexPost
            pollURL = VideoWire.appendQueryAuth(
                base + vgCfg.pollEndpoint.replacingOccurrences(of: "{model}", with: model),
                config: config, apiKey: apiKey
            )
        } else {
            arm = .get
            pollURL = VideoWire.appendQueryAuth(
                base + vgCfg.pollEndpoint.replacingOccurrences(of: "{id}", with: id),
                config: config, apiKey: apiKey
            )
        }

        self.providerName = provider
        self.spec = config
        self.vgCfg = vgCfg
        self.base = base
        self.headers = headers
        self.handleModel = model
        self.raw = raw
        self.http = http
        self.arm = arm
        self.pollURL = pollURL
        self.lc = LifecycleConfig(
            noun: "video generation",
            provider: config.slug,
            id: id,
            statusPath: "",
            doneValues: [],
            errorValues: [],
            errorMessagePath: "",
            pollInterval: 5,
            pollTimeout: 600
        )
        self.apiKey = apiKey
    }

    func poll() async throws -> PollBody {
        let (status, data): (Int, Data)
        switch arm {
        case .sigv4:
            let env = ProcessInfo.processInfo.environment
            let region = env[spec.regionEnvVar] ?? ""
            let secretKey = env[spec.secretKeyEnvVar] ?? ""
            let sessionToken = spec.sessionTokenEnvVar.isEmpty ? "" : (env[spec.sessionTokenEnvVar] ?? "")
            (status, data) = try await http.getTextSigV4(
                url: pollURL, accessKey: apiKey, secretKey: secretKey, sessionToken: sessionToken,
                region: region, service: spec.serviceName, callerHeaders: []
            )
        case .vertexPost:
            (status, data) = try await http.postJSON(
                url: pollURL, body: .object([("operationName", .string(lc.id))]), headers: headers
            )
        case .get:
            (status, data) = try await http.getText(url: pollURL, headers: headers)
        }
        guard (200..<300).contains(status) else {
            throw LLMKitError.api(provider: "video_poll", statusCode: status, message: String(decoding: data, as: UTF8.self))
        }
        return PollBody(raw: try JSONValue.parse(String(decoding: data, as: UTF8.self)))
    }

    func classify(_ body: PollBody) throws -> Classification {
        try VideoWire.classify(vgCfg, body.value())
    }

    func result(_ body: PollBody) async throws -> VideoResponse {
        var response = try await VideoWire.result(vgCfg, body.value(), base: base, headers: headers, http: http)
        // Download delivery (Veo): the poll result placed a temporary fetch URI in
        // VideoData.url; fetch each and fill VideoData.bytes (clearing url, the
        // source-XOR contract VID-004). Vertex is inline-base64 (no url) — no-op.
        if vgCfg.outputDelivery == "DeliveryDownload" {
            response = try await downloadBytes(response)
        }
        if raw { response.raw = body.value() }
        return response
    }

    /// Fetches finished-video bytes for download-delivery providers, carrying the
    /// query-param auth (Google `?key=`) and moving the payload into bytes.
    private func downloadBytes(_ input: VideoResponse) async throws -> VideoResponse {
        var response = input
        for index in response.videos.indices where !response.videos[index].url.isEmpty {
            let fetchURL = VideoWire.appendQueryAuth(response.videos[index].url, config: spec, apiKey: apiKey)
            let (status, data) = try await http.getText(url: fetchURL, headers: headers)
            guard (200..<300).contains(status) else {
                throw LLMKitError.api(provider: "video_download", statusCode: status, message: String(decoding: data, as: UTF8.self))
            }
            response.videos[index].bytes = [UInt8](data)
            response.videos[index].url = ""
        }
        return response
    }
}

/// Wire-shape-keyed video helpers shared by the submit and poll seams: the base
/// resolver, query-param auth, submit-handle lookup, poll classification, and
/// result extraction. All dispatch on the generated `wireShape` fact, never a
/// provider name (mirror of `video.rs`'s free functions).
enum VideoWire {
    /// Video API base: an override wins, else the provider's distinct video base,
    /// else the chat base — with `{region}` resolved from the region env var.
    static func baseURL(config: ProviderSpec, vgCfg: VideoGenDef, override: String?) -> String {
        if let override { return override }
        var base = vgCfg.videoBaseURL.isEmpty ? config.baseURL : vgCfg.videoBaseURL
        if !config.regionEnvVar.isEmpty {
            let region = ProcessInfo.processInfo.environment[config.regionEnvVar] ?? ""
            base = base.replacingOccurrences(of: "{region}", with: region)
        }
        return base
    }

    /// Appends `?key=`/`&key=` for query-param-auth providers (Google); a no-op
    /// otherwise. Picks the separator by whether the URL already has a query.
    static func appendQueryAuth(_ url: String, config: ProviderSpec, apiKey: String) -> String {
        guard config.authScheme == "QueryParamKey", !config.authQueryParam.isEmpty else { return url }
        let separator = url.contains("?") ? "&" : "?"
        return "\(url)\(separator)\(config.authQueryParam)=\(apiKey)"
    }

    /// Descends a dotted path (e.g. "id", "output.task_id", "Resp.video_id")
    /// through the submit response; a numeric leaf (PixVerse's integer job id) is
    /// formatted back to its integer string.
    static func lookupHandleField(_ raw: JSONValue, _ path: String) -> String {
        guard !path.isEmpty else { return "" }
        switch raw.lookup(path) {
        case let .string(value): return value
        case let .int(value): return String(value)
        default: return ""
        }
    }

    /// Classifies one poll body per wire shape (port of `parse_video_poll`).
    /// Returns running / succeeded / failed; an unknown shape fails loud.
    static func classify(_ vgCfg: VideoGenDef, _ raw: JSONValue) throws -> Classification {
        switch vgCfg.wireShape {
        case "VideoQwen":
            let status = raw.stringValue(at: "output.task_status")
            switch status {
            case "SUCCEEDED": return succeeded(status)
            case "FAILED", "CANCELED": return failed(status, "")
            default: return running(status)
            }
        case "VideoTogether":
            let status = raw.stringValue(at: "status")
            switch status {
            case "completed": return succeeded(status)
            case "failed", "cancelled": return failed(status, "")
            default: return running(status)
            }
        case "VideoZhipu":
            let status = raw.stringValue(at: "task_status")
            switch status {
            case "SUCCESS": return succeeded(status)
            case "FAIL": return failed(status, "")
            default: return running(status)
            }
        case "VideoVidu":
            let state = raw.stringValue(at: "state")
            switch state {
            case "success": return succeeded(state)
            case "failed":
                let msg = firstNonEmpty(raw.stringValue(at: "err_code"), raw.stringValue(at: "message"))
                return failed(state, msg)
            default: return running(state)
            }
        case "VideoPixVerse":
            // Status is an INTEGER code nested under Resp: 1=success, 7/8=failed,
            // 5=generating.
            let status = raw.member("Resp")?.intValue(at: "status") ?? -1
            switch status {
            case 1: return succeeded(String(status))
            case 7, 8: return failed(String(status), "")
            default: return running(String(status))
            }
        case "VideoMinimax":
            // Two-hop: success yields a file_id (resolved in result), not a URL.
            let status = raw.stringValue(at: "status")
            switch status {
            case "Success": return succeeded(status)
            case "Fail": return failed(status, "")
            default: return running(status)
            }
        case "VideoVeo", "VideoVertexVeo":
            // Operation-based LRO: poll until done==true. A done op with an error
            // object is a terminal failure; otherwise the finished video is in the
            // response (extracted in result, which guards the empty-uri case).
            guard case let .bool(done)? = raw.member("done"), done else { return running("") }
            if let err = raw.member("error"), case .object = err {
                return failed("error", raw.stringValue(at: "error.message"))
            }
            return succeeded("done")
        case "VideoBedrock":
            let status = raw.stringValue(at: "status")
            switch status {
            case "Completed": return succeeded(status)
            case "Failed": return failed(status, raw.stringValue(at: "failureMessage"))
            default: return running(status)
            }
        case "VideoGrok":
            let status = raw.stringValue(at: "status")
            switch status {
            case "done": return succeeded(status)
            case "failed", "expired":
                return failed(status, raw.stringValue(at: "error.message"))
            default: return running(status)
            }
        default:
            throw LLMKitError.unsupported("video poll: unsupported wire shape \"\(vgCfg.wireShape)\"")
        }
    }

    /// Extracts the finished `VideoResponse` per wire shape (the
    /// `video_result_from_*` family). Only called on a succeeded classification.
    static func result(
        _ vgCfg: VideoGenDef, _ raw: JSONValue, base: String, headers: [(String, String)], http: HTTPClient
    ) async throws -> VideoResponse {
        let mime = fallbackMime(vgCfg)
        switch vgCfg.wireShape {
        case "VideoGrok":
            guard let video = raw.member("video"), case .object = video else { return VideoResponse.default() }
            return single(mime: mime, url: video.stringValue(at: "url"), duration: video.intValue(at: "duration"))
        case "VideoZhipu":
            return urlResult(mime: mime, url: stringAt(raw, "video_result[0].url"))
        case "VideoVidu":
            return urlResult(mime: mime, url: stringAt(raw, "creations[0].url"))
        case "VideoTogether":
            return urlResult(mime: mime, url: raw.stringValue(at: "outputs.video_url"))
        case "VideoQwen":
            return urlResult(mime: mime, url: raw.stringValue(at: "output.video_url"))
        case "VideoPixVerse":
            return urlResult(mime: mime, url: raw.stringValue(at: "Resp.url"))
        case "VideoBedrock":
            let url = raw.stringValue(at: "outputDataConfig.s3OutputDataConfig.s3Uri")
            if url.isEmpty {
                throw LLMKitError.unsupported("video generation: completed but carried no output s3 uri")
            }
            return single(mime: mime, url: url, duration: 0)
        case "VideoVeo":
            let url = stringAt(raw, "response.generateVideoResponse.generatedSamples[0].video.uri")
            if url.isEmpty {
                throw LLMKitError.unsupported("video generation: operation done but carried no video uri")
            }
            return single(mime: mime, url: url, duration: 0)
        case "VideoVertexVeo":
            let first = raw.lookup("response.videos[0]")
            var vmime = mime
            if let echoed = first?.member("mimeType"), case let .string(m) = echoed, !m.isEmpty { vmime = m }
            let b64 = first?.member("bytesBase64Encoded").flatMap { if case let .string(s) = $0 { return s }; return nil } ?? ""
            guard !b64.isEmpty, let decoded = Data(base64Encoded: b64) else {
                throw LLMKitError.unsupported("video generation: operation done but carried no video bytes")
            }
            return VideoResponse(
                videos: [VideoData(mimeType: vmime, url: "", bytes: [UInt8](decoded), durationSeconds: 0)],
                usage: Usage(), finishReason: "", finishMessage: "", raw: nil
            )
        case "VideoMinimax":
            // Two-hop: the terminal poll carried a file_id, not a URL — resolve it
            // with one more GET (file-retrieve) before returning.
            return try await resolveFile(vgCfg, raw, base: base, headers: headers, http: http, mime: mime)
        default:
            return VideoResponse.default()
        }
    }

    /// The MiniMax file-retrieve hop: reads file_id from the terminal poll, GETs
    /// the file endpoint, and extracts file.download_url.
    private static func resolveFile(
        _ vgCfg: VideoGenDef, _ poll: JSONValue, base: String, headers: [(String, String)],
        http: HTTPClient, mime: String
    ) async throws -> VideoResponse {
        let fileID: String
        switch poll.member("file_id") {
        case let .string(s): fileID = s
        case let .int(n): fileID = String(n)
        default: fileID = ""
        }
        guard !fileID.isEmpty else {
            throw LLMKitError.unsupported("video file hop: terminal poll carried no file_id")
        }
        let url = base + vgCfg.fileEndpoint.replacingOccurrences(of: "{file_id}", with: fileID)
        let (status, data) = try await http.getText(url: url, headers: headers)
        guard (200..<300).contains(status) else {
            throw LLMKitError.api(provider: "video_file_retrieve", statusCode: status, message: String(decoding: data, as: UTF8.self))
        }
        let fileRaw = try JSONValue.parse(String(decoding: data, as: UTF8.self))
        return urlResult(mime: mime, url: fileRaw.stringValue(at: "file.download_url"))
    }

    // MARK: - Small builders

    private static func fallbackMime(_ vgCfg: VideoGenDef) -> String {
        vgCfg.models.first?.outputMime ?? "video/mp4"
    }

    private static func single(mime: String, url: String, duration: Int) -> VideoResponse {
        VideoResponse(
            videos: [VideoData(mimeType: mime, url: url, bytes: [], durationSeconds: duration)],
            usage: Usage(), finishReason: "", finishMessage: "", raw: nil
        )
    }

    /// A url-delivery result, or an empty response when the URL is absent (matches
    /// the Rust `video_result_from_*` empty-url guard).
    private static func urlResult(mime: String, url: String) -> VideoResponse {
        url.isEmpty ? VideoResponse.default() : single(mime: mime, url: url, duration: 0)
    }

    private static func stringAt(_ raw: JSONValue, _ path: String) -> String {
        raw.stringValue(at: path)
    }

    private static func succeeded(_ status: String) -> Classification {
        Classification(state: .succeeded, failure: nil, rawStatus: status)
    }

    private static func failed(_ status: String, _ message: String) -> Classification {
        Classification(state: .failed, failure: JobFailure(status: status, message: message), rawStatus: status)
    }

    private static func running(_ status: String) -> Classification {
        Classification(state: .running, failure: nil, rawStatus: status)
    }

    private static func firstNonEmpty(_ a: String, _ b: String) -> String {
        !a.isEmpty ? a : (!b.isEmpty ? b : "operation failed")
    }
}

extension VideoResponse {
    /// The empty video response (a failed or still-empty poll).
    static func `default`() -> VideoResponse {
        VideoResponse(videos: [], usage: Usage(), finishReason: "", finishMessage: "", raw: nil)
    }
}
