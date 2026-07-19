import XCTest

@testable import LLMKit

///
///
///
///
///
///
final class CustomHeadersTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    ///
    func testCustomHeaderReachesChatRequest() async throws {
        MockURLProtocol.responseBody = Data("{}".utf8)
        let client = Client(provider: .anthropic, apiKey: "test-key", session: MockURLProtocol.makeSession())
            .addHeader("X-Custom", "v")

        _ = try await client.text.model("claude-sonnet-4-6").maxTokens(16).prompt("hello")

        //
        XCTAssertEqual(MockURLProtocol.capturedHeaders["x-custom"], "v")
        XCTAssertEqual(MockURLProtocol.capturedHeaders["x-api-key"], "test-key")
    }

    ///
    func testCustomHeaderReachesCatalogueRequest() async throws {
        let body = #"{"data":[{"id":"gpt-5","object":"model","created":1715367049,"owned_by":"system"}]}"#
        MockURLProtocol.responseBody = Data(body.utf8)
        let client = Client(provider: .openai, apiKey: "test-key", session: MockURLProtocol.makeSession())
            .baseURL("https://mock.test")
            .addHeader("X-Custom", "v")

        let models = try await client.models.provider(.openai).list()

        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(MockURLProtocol.capturedHeaders["x-custom"], "v")
        //
        XCTAssertEqual(MockURLProtocol.capturedHeaders["authorization"], "Bearer test-key")
    }

    ///
    ///
    func testCaseInsensitiveCollisionDoesNotClobberAuth() async throws {
        MockURLProtocol.responseBody = Data("{}".utf8)
        let client = Client(provider: .anthropic, apiKey: "test-key", session: MockURLProtocol.makeSession())
            .addHeader("X-API-KEY", "attacker-value")

        _ = try await client.text.model("claude-sonnet-4-6").maxTokens(16).prompt("hello")

        //
        XCTAssertEqual(MockURLProtocol.capturedHeaders["x-api-key"], "test-key")
    }
}
