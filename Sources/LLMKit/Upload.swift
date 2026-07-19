import Foundation

///
///
///
///
///
///
///
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

    ///
    ///
    public func path(_ value: String) -> Upload { with { $0.path = value } }

    ///
    public func bytes(_ value: Data) -> Upload { with { $0.bytes = value } }

    ///
    public func filename(_ value: String) -> Upload { with { $0.filename = value } }

    ///
    public func mimeType(_ value: String) -> Upload { with { $0.mimeType = value } }

    ///
    public func addMiddleware(_ hook: @escaping MiddlewareFn) -> Upload {
        with { $0.middleware.append(hook) }
    }

    ///
    private func with(_ mutate: (inout Upload) -> Void) -> Upload {
        var copy = self
        mutate(&copy)
        return copy
    }

    ///
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
            //
            //
            //
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

    //

    ///
    ///
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
            Middleware.setError(&postEvent, error)
            Middleware.firePost(middleware, postEvent)
            throw error
        }
    }

    ///
    private static func send(
        config: ProviderSpec, upload: FileUploadDef, apiKey: String,
        baseURLOverride: String?, http: HTTPClient,
        data: Data, filename: String, mime: String
    ) async throws -> File {
        let base = baseURLOverride ?? config.baseURL
        var url = base + upload.endpoint
        if config.authScheme == "QueryParamKey" && !config.authQueryParam.isEmpty {
            let separator = url.contains("?") ? "&" : "?"
            url += "\(separator)\(config.authQueryParam)=\(urlencode(apiKey))"
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

        //
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

    ///
    ///
    ///
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
