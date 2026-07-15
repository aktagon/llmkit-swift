import Foundation

/// Thin transport over Foundation `URLSession` (ADR-066 SWIFT-003). The session
/// is injected so tests can supply a mock (a `URLProtocol`-backed session), the
/// key testability hook for the request-wire driver.
struct HTTPClient: Sendable {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
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
    /// the exact bytes sent; `callerHeaders` (ADR-052) ride alongside unsigned.
    func postJSONSigV4(
        url: String,
        body: JSONValue,
        accessKey: String,
        secretKey: String,
        sessionToken: String,
        region: String,
        service: String,
        callerHeaders: [(String, String)]
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
        for (name, value) in callerHeaders { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = payload

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
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMKitError.transport("non-HTTP response")
        }
        return (http.statusCode, data)
    }

    /// POST a `multipart/form-data` body with text fields + one file part. Used
    /// by the OpenAI batch file-reference upload hop.
    func postMultipart(
        url: String,
        fields: [(String, String)],
        file: (field: String, filename: String, data: Data),
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
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(file.field)\"; filename=\"\(file.filename)\"\r\n")
        append("Content-Type: application/octet-stream\r\n\r\n")
        payload.append(file.data)
        append("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = payload

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
