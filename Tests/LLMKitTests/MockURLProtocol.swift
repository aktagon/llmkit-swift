import Foundation

/// A `URLProtocol` that captures the outbound request body and returns a canned
/// response, letting the request-wire driver assert the exact bytes the SDK
/// builds without a live network call. Installed via an injected `URLSession`.
final class MockURLProtocol: URLProtocol {
    static var capturedBody: Data?
    static var responseStatusCode = 200
    static var responseBody = Data()

    static func reset() {
        capturedBody = nil
        responseStatusCode = 200
        responseBody = Data()
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
        if let url = request.url,
           let response = HTTPURLResponse(
               url: url,
               statusCode: MockURLProtocol.responseStatusCode,
               httpVersion: nil,
               headerFields: nil
           ) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: MockURLProtocol.responseBody)
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
