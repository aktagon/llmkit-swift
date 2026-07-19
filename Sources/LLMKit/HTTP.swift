import Foundation

///
///
///
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

///
///
///
struct HTTPClient: Sendable {
    let session: URLSession
    ///
    ///
    ///
    ///
    ///
    ///
    ///
    let customHeaders: [(String, String)]

    init(session: URLSession = .shared, customHeaders: [(String, String)] = []) {
        self.session = session
        self.customHeaders = customHeaders
    }

    ///
    ///
    ///
    ///
    private func applyCustomHeaders(_ request: inout URLRequest) {
        for (name, value) in customHeaders where request.value(forHTTPHeaderField: name) == nil {
            request.setValue(value, forHTTPHeaderField: name)
        }
    }

    ///
    ///
    ///
    ///
    func postJSON(
        url: String,
        body: JSONValue,
        headers: [(String, String)]
    ) async throws -> (statusCode: Int, data: Data) {
        guard let endpoint = URL(string: url) else {
            throw LLMKitError.validation(field: "url", message: "invalid URL")
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

    ///
    ///
    ///
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
            throw LLMKitError.validation(field: "url", message: "invalid URL")
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

    ///
    ///
    ///
    ///
    ///
    ///
    func getTextSigV4(
        url: String,
        accessKey: String,
        secretKey: String,
        sessionToken: String,
        region: String,
        service: String
    ) async throws -> (statusCode: Int, data: Data) {
        guard let endpoint = URL(string: url) else {
            throw LLMKitError.validation(field: "url", message: "invalid URL")
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

    ///
    ///
    func getText(url: String, headers: [(String, String)]) async throws -> (statusCode: Int, data: Data) {
        guard let endpoint = URL(string: url) else {
            throw LLMKitError.validation(field: "url", message: "invalid URL")
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

    ///
    ///
    ///
    ///
    private func escapeQuotes(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }

    ///
    ///
    ///
    ///
    ///
    ///
    ///
    func postMultipart(
        url: String,
        fields: [(String, String)],
        file: (field: String, filename: String, contentType: String, data: Data),
        headers: [(String, String)]
    ) async throws -> (statusCode: Int, data: Data) {
        guard let endpoint = URL(string: url) else {
            throw LLMKitError.validation(field: "url", message: "invalid URL")
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

    ///
    ///
    ///
    func postBytes(
        url: String,
        body: Data,
        headers: [(String, String)]
    ) async throws -> (statusCode: Int, data: Data) {
        guard let endpoint = URL(string: url) else {
            throw LLMKitError.validation(field: "url", message: "invalid URL")
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

    ///
    ///
    ///
    func openStream(
        url: String,
        body: JSONValue,
        headers: [(String, String)]
    ) async throws -> (statusCode: Int, lines: AsyncLineSequence<URLSession.AsyncBytes>) {
        guard let endpoint = URL(string: url) else {
            throw LLMKitError.validation(field: "url", message: "invalid URL")
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
