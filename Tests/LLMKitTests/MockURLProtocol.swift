import Foundation

///
///
///
final class MockURLProtocol: URLProtocol {
    static var capturedBody: Data?
    ///
    ///
    ///
    static var capturedBodies: [Data] = []
    static var capturedHeaders: [String: String] = [:]
    ///
    ///
    static var capturedURLs: [String] = []
    static var responseStatusCode = 200
    static var responseBody = Data()
    ///
    ///
    static var responseSequence: [Data]?
    private static var sequenceIndex = 0

    static func reset() {
        capturedBody = nil
        capturedBodies = []
        capturedHeaders = [:]
        capturedURLs = []
        responseStatusCode = 200
        responseBody = Data()
        responseSequence = nil
        sequenceIndex = 0
    }

    ///
    private static func nextBody() -> Data {
        guard let sequence = responseSequence, !sequence.isEmpty else { return responseBody }
        let index = min(sequenceIndex, sequence.count - 1)
        sequenceIndex += 1
        return sequence[index]
    }

    ///
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        MockURLProtocol.capturedBody = MockURLProtocol.body(from: request)
        if let body = MockURLProtocol.capturedBody {
            MockURLProtocol.capturedBodies.append(body)
        }
        if let url = request.url?.absoluteString {
            MockURLProtocol.capturedURLs.append(url)
        }
        //
        //
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

    ///
    ///
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
