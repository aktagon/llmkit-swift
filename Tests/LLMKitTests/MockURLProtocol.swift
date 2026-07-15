import Foundation

/// A `URLProtocol` that captures the outbound request body and returns a canned
/// response, letting the request-wire driver assert the exact bytes the SDK
/// builds without a live network call. Installed via an injected `URLSession`.
final class MockURLProtocol: URLProtocol {
    static var capturedBody: Data?
    static var capturedHeaders: [String: String] = [:]
    static var responseStatusCode = 200
    static var responseBody = Data()
    /// When set, successive requests are served the queued bodies in order (the
    /// last entry repeats). Drives the two-hop batch poll + result fetch.
    static var responseSequence: [Data]?
    private static var sequenceIndex = 0

    static func reset() {
        capturedBody = nil
        capturedHeaders = [:]
        responseStatusCode = 200
        responseBody = Data()
        responseSequence = nil
        sequenceIndex = 0
    }

    /// The body to serve for the current request, advancing the sequence.
    private static func nextBody() -> Data {
        guard let sequence = responseSequence, !sequence.isEmpty else { return responseBody }
        let index = min(sequenceIndex, sequence.count - 1)
        sequenceIndex += 1
        return sequence[index]
    }

    /// A session whose only transport is this mock protocol.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        MockURLProtocol.capturedBody = MockURLProtocol.body(from: request)
        // Lowercase the header keys to match the cross-SDK comparator's
        // case-insensitive subset match (HANDOFF-028).
        var headers: [String: String] = [:]
        for (key, value) in request.allHTTPHeaderFields ?? [:] {
            headers[key.lowercased()] = value
        }
        MockURLProtocol.capturedHeaders = headers
        if let url = request.url,
           let response = HTTPURLResponse(
               url: url,
               statusCode: MockURLProtocol.responseStatusCode,
               httpVersion: nil,
               headerFields: nil
           ) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: MockURLProtocol.nextBody())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession moves `httpBody` into `httpBodyStream` before the protocol
    /// sees the request, so read the stream when the plain body is nil.
    private static func body(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
