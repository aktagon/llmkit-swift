import Foundation

/// The Files API builder (ADR-060 / CR-004). `client.upload().path(p).run()`
/// uploads a file to the provider and returns a `File` handle to attach to a
/// later prompt via `.file(id)`. `path()` and `bytes()` are mutually exclusive —
/// exactly one must be set; `filename()` is required with `bytes()` (no path to
/// derive a name from) and overrides the derived name with `path()`; `mimeType()`
/// overrides extension-based detection. Fires the `upload` MiddlewareOp.
/// Mirrors Go `Upload`/`Run`, TS/Python/Rust `upload().run()`.
public struct Upload: Sendable {
    let provider: ProviderName
    let apiKey: String
    let baseURLOverride: String?
    let http: HTTPClient
    var path: String = ""
    var bytes: Data = Data()
    var filename: String = ""
    var mimeType: String = ""
    var middleware: [MiddlewareFn] = []

    init(provider: ProviderName, apiKey: String, baseURLOverride: String?, http: HTTPClient) {
        self.provider = provider
        self.apiKey = apiKey
        self.baseURLOverride = baseURLOverride
        self.http = http
    }

    /// Read the upload payload from a filesystem path. The multipart filename
    /// defaults to the path's last component unless `filename()` overrides it.
    public func path(_ value: String) -> Upload { with { $0.path = value } }

    /// Upload the given bytes directly. `filename()` is required in this mode.
    public func bytes(_ value: Data) -> Upload { with { $0.bytes = value } }

    /// Override the multipart filename.
    public func filename(_ value: String) -> Upload { with { $0.filename = value } }

    /// Override the file part's Content-Type (else inferred from the filename).
    public func mimeType(_ value: String) -> Upload { with { $0.mimeType = value } }

    /// Register a middleware hook for this upload (observes/vetoes the `upload` op).
    public func addMiddleware(_ hook: @escaping MiddlewareFn) -> Upload {
        with { $0.middleware.append(hook) }
    }

    /// Clone-on-chain helper (ADR-066 SWIFT-004): copy, mutate, return.
    private func with(_ mutate: (inout Upload) -> Void) -> Upload {
        var copy = self
        mutate(&copy)
        return copy
    }

    /// Upload the configured file and return its `File` handle.
    public func run() async throws -> File {
        let hasPath = !path.isEmpty
        let hasBytes = !bytes.isEmpty
        if !hasPath && !hasBytes {
            throw LLMKitError.validation(field: "Upload", message: "exactly one of path() or bytes() must be set")
        }
        if hasPath && hasBytes {
            throw LLMKitError.validation(field: "Upload", message: "path() and bytes() are mutually exclusive")
        }

        let data: Data
        let name: String
        if hasPath {
            // Reject pathologically large files before allocating — well above
            // any provider's real upload limit, but blocks a trivial OOM via
            // path("/dev/zero"). Mirrors Go's guard.
            let maxUploadBytes = 1 << 30 // 1GB
            if let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int,
               size > maxUploadBytes {
                throw LLMKitError.validation(field: "path", message: "file too large: \(size) bytes exceeds \(maxUploadBytes) limit")
            }
            do {
                data = try Data(contentsOf: URL(fileURLWithPath: path))
            } catch {
                throw LLMKitError.unsupported("cannot read \(path): \(error)")
            }
            name = filename.isEmpty ? URL(fileURLWithPath: path).lastPathComponent : filename
        } else {
            guard !filename.isEmpty else {
                throw LLMKitError.validation(field: "Upload", message: "filename() is required when bytes() is set")
            }
            data = bytes
            name = filename
        }

        return try await Upload.uploadData(
            provider: provider, apiKey: apiKey, baseURLOverride: baseURLOverride,
            http: http, data: data, filename: name, mime: mimeType, middleware: middleware
        )
    }

    // MARK: - Transport (fire + multipart)

    /// Fires the `upload` op around the multipart POST (mirrors Rust
    /// `upload_with_data` — pre/post middleware with duration + error capture).
    static func uploadData(
        provider: ProviderName, apiKey: String, baseURLOverride: String?, http: HTTPClient,
        data: Data, filename: String, mime: String, middleware: [MiddlewareFn]
    ) async throws -> File {
        let config = providerConfig(provider)
        guard let upload = fileUploadConfig(provider) else {
            throw LLMKitError.validation(field: "provider", message: "file upload not supported: \(config.slug)")
        }
        let model = try RequestBuilder.resolveModel(config, nil)

        let baseEvent = Event(op: .upload, provider: provider.rawValue, model: model)
        let start = Date()
        try Middleware.firePre(middleware, baseEvent)

        var postEvent = baseEvent
        do {
            let file = try await send(
                config: config, upload: upload, apiKey: apiKey,
                baseURLOverride: baseURLOverride, http: http,
                data: data, filename: filename, mime: mime
            )
            postEvent.duration = Date().timeIntervalSince(start)
            Middleware.firePost(middleware, postEvent)
            return file
        } catch {
            postEvent.duration = Date().timeIntervalSince(start)
            postEvent.err = "\(error)"
            Middleware.firePost(middleware, postEvent)
            throw error
        }
    }

    /// The multipart POST + response-path parse (mirrors Rust `upload_file_inner`).
    private static func send(
        config: ProviderSpec, upload: FileUploadDef, apiKey: String,
        baseURLOverride: String?, http: HTTPClient,
        data: Data, filename: String, mime: String
    ) async throws -> File {
        let base = baseURLOverride ?? config.baseURL
        var url = base + upload.endpoint
        if config.authScheme == "QueryParamKey" && !config.authQueryParam.isEmpty {
            let separator = url.contains("?") ? "&" : "?"
            url += "\(separator)\(config.authQueryParam)=\(apiKey)"
        }

        var headers = RequestBuilder.buildAuthHeaders(config: config, apiKey: apiKey)
        if !upload.betaHeader.isEmpty {
            headers.append(("anthropic-beta", upload.betaHeader))
        }

        var mimeType = mime
        if mimeType.isEmpty { mimeType = detectMimeType(filename) }

        var fields: [(String, String)] = []
        if !upload.extraFieldsJSON.isEmpty,
           case let .object(pairs) = (try? JSONValue.parse(upload.extraFieldsJSON)) ?? .null {
            for (key, value) in pairs {
                if case let .string(text) = value { fields.append((key, text)) }
            }
        }

        // Google carries the filename as a JSON metadata form field + a protocol header.
        if config.chatWireShape == "ChatGoogle" {
            let metadata = JSONValue.object([
                ("file", .object([("display_name", .string(filename))]))
            ])
            fields.append(("metadata", metadata.serialized()))
            headers.append(("X-Goog-Upload-Protocol", "multipart"))
        }

        let (status, body) = try await http.postMultipart(
            url: url,
            fields: fields,
            file: (field: upload.fieldName, filename: filename, contentType: mimeType, data: data),
            headers: headers
        )
        guard (200..<300).contains(status) else {
            throw ResponseParser.parseError(config: config, statusCode: status, body: body)
        }

        let parsed = try JSONValue.parse(String(decoding: body, as: UTF8.self))
        var file = File(id: "", uri: "", mimeType: mimeType, name: filename)
        if !upload.responseIdPath.isEmpty { file.id = parsed.stringValue(at: upload.responseIdPath) }
        if !upload.responseUriPath.isEmpty { file.uri = parsed.stringValue(at: upload.responseUriPath) }
        if !upload.responseNamePath.isEmpty { file.name = parsed.stringValue(at: upload.responseNamePath) }
        if !upload.responseMimePath.isEmpty { file.mimeType = parsed.stringValue(at: upload.responseMimePath) }
        return file
    }

    /// Extension-based MIME fallback when `mimeType()` is unset (mirrors Go's
    /// `detectMimeType`). The dominant provider (Anthropic) overrides `mimeType`
    /// from the response anyway; this sets the request part's Content-Type.
    static func detectMimeType(_ filename: String) -> String {
        switch (filename as NSString).pathExtension.lowercased() {
        case "pdf": return "application/pdf"
        case "json": return "application/json"
        case "txt": return "text/plain"
        case "md": return "text/markdown"
        case "csv": return "text/csv"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return "application/octet-stream"
        }
    }
}
