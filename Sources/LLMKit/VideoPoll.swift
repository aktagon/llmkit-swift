import Foundation

///
///
///
///
///
///
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
    ///
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
        //
        //
        if vgCfg.wireShape == "VideoPixVerse" {
            headers.append(("Ai-trace-id", Video.newTraceID()))
        }

        //
        //
        //
        let arm: PollArm
        let pollURL: String
        if config.authScheme == "SigV4" {
            arm = .sigv4
            //
            //
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
                region: region, service: spec.serviceName
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
        //
        //
        //
        if vgCfg.outputDelivery == "DeliveryDownload" {
            response = try await downloadBytes(response)
        }
        if raw { response.raw = body.value() }
        return response
    }

    ///
    ///
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

///
///
///
///
enum VideoWire {
    ///
    ///
    static func baseURL(config: ProviderSpec, vgCfg: VideoGenDef, override: String?) -> String {
        if let override { return override }
        var base = vgCfg.videoBaseURL.isEmpty ? config.baseURL : vgCfg.videoBaseURL
        if !config.regionEnvVar.isEmpty {
            let region = ProcessInfo.processInfo.environment[config.regionEnvVar] ?? ""
            base = base.replacingOccurrences(of: "{region}", with: region)
        }
        return base
    }

    ///
    ///
    static func appendQueryAuth(_ url: String, config: ProviderSpec, apiKey: String) -> String {
        guard config.authScheme == "QueryParamKey", !config.authQueryParam.isEmpty else { return url }
        let separator = url.contains("?") ? "&" : "?"
        return "\(url)\(separator)\(config.authQueryParam)=\(urlencode(apiKey))"
    }

    ///
    ///
    ///
    static func lookupHandleField(_ raw: JSONValue, _ path: String) -> String {
        guard !path.isEmpty else { return "" }
        switch raw.lookup(path) {
        case let .string(value): return value
        case let .int(value): return String(value)
        default: return ""
        }
    }

    ///
    ///
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
            //
            //
            let status = raw.member("Resp")?.intValue(at: "status") ?? -1
            switch status {
            case 1: return succeeded(String(status))
            case 7, 8: return failed(String(status), "")
            default: return running(String(status))
            }
        case "VideoMinimax":
            //
            let status = raw.stringValue(at: "status")
            switch status {
            case "Success": return succeeded(status)
            case "Fail": return failed(status, "")
            default: return running(status)
            }
        case "VideoVeo", "VideoVertexVeo":
            //
            //
            //
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

    ///
    ///
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
            //
            //
            return try await resolveFile(vgCfg, raw, base: base, headers: headers, http: http, mime: mime)
        default:
            return VideoResponse.default()
        }
    }

    ///
    ///
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

    //

    private static func fallbackMime(_ vgCfg: VideoGenDef) -> String {
        vgCfg.models.first?.outputMime ?? "video/mp4"
    }

    private static func single(mime: String, url: String, duration: Int) -> VideoResponse {
        VideoResponse(
            videos: [VideoData(mimeType: mime, url: url, bytes: [], durationSeconds: duration)],
            usage: Usage(), finishReason: "", finishMessage: "", raw: nil
        )
    }

    ///
    ///
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
    ///
    static func `default`() -> VideoResponse {
        VideoResponse(videos: [], usage: Usage(), finishReason: "", finishMessage: "", raw: nil)
    }
}
