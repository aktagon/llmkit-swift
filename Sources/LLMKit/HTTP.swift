import Foundation

/// Minimal percent-encoder for query-parameter values (API keys, pagination
/// cursors); escapes everything outside the RFC 3986 unreserved set. Shared by
/// every seam that splices a value into a URL query string.
func urlencode(_ s: String) -> String {
    var out = ""
    for byte in s.utf8 {
        switch byte {
        case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x5F, 0x2E, 0x7E:
            out.unicodeScalars.append(UnicodeScalar(byte))
        default:
            out += String(format: "%%%02X", byte)
        }
    }
    return out
}

/// Thin transport over Foundation `URLSession` (ADR-066 SWIFT-003). The session
/// is injected so tests can supply a mock (a `URLProtocol`-backed session), the
/// key testability hook for the request-wire driver.
struct HTTPClient: Sendable {
    let session: URLSession
    /// Caller custom headers attached to every request (ADR-052, added via
    /// `Client.addHeader`). Empty by default. Applied AFTER the SDK-set headers
    /// (provider auth + required header + signature) and skipped when a header of
    /// the same name already exists (case-insensitively), so a gateway header
    /// (e.g. cf-aig-authorization) rides alongside the provider key and can never
    /// clobber it. The single seam: because `http` is threaded to every builder
    /// and the catalogue path, carrying the headers here reaches every send path.
    let customHeaders: [(String, String)]

    init(session: URLSession = .shared, customHeaders: [(String, String)] = []) {
        self.session = session
        self.customHeaders = customHeaders
    }

    /// Append the caller custom headers, skipping any name already present on the
    /// request (HTTP header names are case-insensitive; `value(forHTTPHeaderField:)`
    /// matches case-insensitively). Mirrors Rust `build_catalogue_headers`'s and
    /// `apply_unsigned_headers`'s collision skip.
    private func applyCustomHeaders(_ request: inout URLRequest) {
        for (name, value) in customHeaders where request.value(forHTTPHeaderField: name) == nil {
            request.setValue(value, forHTTPHeaderField: name)
        }
    }

    /// POST a JSON body and return the status code + raw response bytes. The
    /// body is serialized through the hand-rolled `JSONValue` serializer (never
    /// `JSONEncoder`), so the outbound bytes are exactly what the wire goldens
    /// assert.
    func postJSON(
        url: String,
        body: JSONValue,
        headers: [(String, String)]
    ) async throws -> (statusCode: Int, data: Data) {
        guard let endpoint = URL(string: url) else {
            throw LLMKitError.validation(field: "url", message: "invalid URL: \(url)")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        applyCustomHeaders(&request)
        guard let payload = body.serialized().data(using: .utf8) else {
            throw LLMKitError.validation(field: "body", message: "could not UTF-8 encode request body")
        }
        request.httpBody = payload

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMKitError.transport("non-HTTP response")
        }
        return (http.statusCode, data)
    }

    /// POST a JSON body signed with AWS SigV4 (Bedrock). The signature covers
    /// the exact bytes sent; the caller custom headers (ADR-052) ride alongside
    /// unsigned, skipping any already-signed header so the signature is intact.
    func postJSONSigV4(
        url: String,
        body: JSONValue,
        accessKey: String,
        secretKey: String,
        sessionToken: String,
        region: String,
        service: String
    ) async throws -> (statusCode: Int, data: Data) {
        guard let endpoint = URL(string: url) else {
            throw LLMKitError.validation(field: "url", message: "invalid URL: \(url)")
        }
        guard let payload = body.serialized().data(using: .utf8) else {
            throw LLMKitError.validation(field: "body", message: "could not UTF-8 encode request body")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let signed = SigV4.sign(
            method: "POST", url: endpoint, body: payload,
            accessKey: accessKey, secretKey: secretKey, sessionToken: sessionToken,
            region: region, service: service, contentType: "application/json"
        )
        for (name, value) in signed { request.setValue(value, forHTTPHeaderField: name) }
        applyCustomHeaders(&request)
        request.httpBody = payload

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMKitError.transport("non-HTTP response")
        }
        return (http.statusCode, data)
    }

    /// GET a URL signed with AWS SigV4 (Bedrock async-invoke poll). The empty
    /// body is signed too, but NO Content-Type: the GET sends none, and a
    /// signed-but-never-sent header is a guaranteed 403 (AWS recomputes the
    /// canonical request from the headers it receives). The caller custom
    /// headers (ADR-052) ride alongside unsigned, skipping any already-signed
    /// header so the signature is intact.
    func getTextSigV4(
        url: String,
        accessKey: String,
        secretKey: String,
        sessionToken: String,
        region: String,
        service: String
    ) async throws -> (statusCode: Int, data: Data) {
        guard let endpoint = URL(string: url) else {
            throw LLMKitError.validation(field: "url", message: "invalid URL: \(url)")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        let signed = SigV4.sign(
            method: "GET", url: endpoint, body: Data(),
            accessKey: accessKey, secretKey: secretKey, sessionToken: sessionToken,
            region: region, service: service, contentType: ""
        )
        for (name, value) in signed { request.setValue(value, forHTTPHeaderField: name) }
        applyCustomHeaders(&request)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMKitError.transport("non-HTTP response")
        }
        return (http.statusCode, data)
    }

    /// GET a URL and return the status code + raw response bytes. Used by the
    /// batch poll + result-fetch hops.
    func getText(url: String, headers: [(String, String)]) async throws -> (statusCode: Int, data: Data) {
        guard let endpoint = URL(string: url) else {
            throw LLMKitError.validation(field: "url", message: "invalid URL: \(url)")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        applyCustomHeaders(&request)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMKitError.transport("non-HTTP response")
        }
        return (http.statusCode, data)
    }

    /// Mirrors Go stdlib mime/multipart escapeQuotes and additionally strips
    /// CR/LF: a quote or newline in a caller-controlled field name or filename
    /// must not break out of the Content-Disposition part header
    /// (HANDOFF-036 A2).
    private func escapeQuotes(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }

    /// POST a `multipart/form-data` body with text fields + one file part. Used
    /// by the OpenAI batch file-reference upload hop and the OpenAI synchronous
    /// transcription request (ADR-051). The file part carries its own
    /// `contentType` so the transcription wire golden asserts the real audio mime
    /// (audio/mpeg), not a blanket octet-stream. Fields are emitted in the caller's
    /// order so the encoded body decodes to the same canonical descriptor across
    /// all four SDKs (ADR-051 OQ-3).
    func postMultipart(
        url: String,
        fields: [(String, String)],
        file: (field: String, filename: String, contentType: String, data: Data),
        headers: [(String, String)]
    ) async throws -> (statusCode: Int, data: Data) {
        guard let endpoint = URL(string: url) else {
            throw LLMKitError.validation(field: "url", message: "invalid URL: \(url)")
        }
        let boundary = "llmkit-boundary-\(UUID().uuidString)"
        var payload = Data()
        func append(_ string: String) { payload.append(Data(string.utf8)) }
        for (name, value) in fields {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(escapeQuotes(name))\"\r\n\r\n")
            append("\(value)\r\n")
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(escapeQuotes(file.field))\"; filename=\"\(escapeQuotes(file.filename))\"\r\n")
        append("Content-Type: \(file.contentType)\r\n\r\n")
        payload.append(file.data)
        append("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        applyCustomHeaders(&request)
        request.httpBody = payload

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMKitError.transport("non-HTTP response")
        }
        return (http.statusCode, data)
    }

    /// POST raw bytes with an `application/octet-stream` body. Used by the
    /// AssemblyAI transcription upload hop (STT-005): local audio bytes are
    /// uploaded first to obtain a URL the JSON submit body can reference.
    func postBytes(
        url: String,
        body: Data,
        headers: [(String, String)]
    ) async throws -> (statusCode: Int, data: Data) {
        guard let endpoint = URL(string: url) else {
            throw LLMKitError.validation(field: "url", message: "invalid URL: \(url)")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        applyCustomHeaders(&request)
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMKitError.transport("non-HTTP response")
        }
        return (http.statusCode, data)
    }

    /// Open a streaming (SSE) POST. Returns the status code and the line
    /// sequence; the caller parses `event:` / `data:` frames. `bytes(for:)`
    /// delivers the body incrementally over `URLSession`.
    func openStream(
        url: String,
        body: JSONValue,
        headers: [(String, String)]
    ) async throws -> (statusCode: Int, lines: AsyncLineSequence<URLSession.AsyncBytes>) {
        guard let endpoint = URL(string: url) else {
            throw LLMKitError.validation(field: "url", message: "invalid URL: \(url)")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        applyCustomHeaders(&request)
        guard let payload = body.serialized().data(using: .utf8) else {
            throw LLMKitError.validation(field: "body", message: "could not UTF-8 encode request body")
        }
        request.httpBody = payload

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMKitError.transport("non-HTTP response")
        }
        return (http.statusCode, bytes.lines)
    }
}
