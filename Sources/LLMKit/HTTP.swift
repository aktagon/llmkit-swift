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
}
