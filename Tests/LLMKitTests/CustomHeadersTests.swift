import XCTest

@testable import LLMKit

/// ADR-052 CCM-004/005 (Swift, HANDOFF-034 Task 3): a caller custom header added
/// via `Client.addHeader` reaches the wire on every send path — asserted here on
/// both a chat request and a catalogue (`models.provider(_).list()`) request —
/// alongside the provider auth header, and never clobbers it even when the
/// caller's header name differs only in case. Mirror of the per-SDK
/// header-capture tests (go/llmkit_test.go, ts/tests, python/tests, rust/tests).
final class CustomHeadersTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    /// Custom header rides a chat request alongside the provider auth header.
    func testCustomHeaderReachesChatRequest() async throws {
        MockURLProtocol.responseBody = Data("{}".utf8)
        let client = Client(provider: .anthropic, apiKey: "test-key", session: MockURLProtocol.makeSession())
            .addHeader("X-Custom", "v")

        _ = try await client.text.model("claude-sonnet-4-6").maxTokens(16).prompt("hello")

        // Custom header present, provider auth (x-api-key) intact.
        XCTAssertEqual(MockURLProtocol.capturedHeaders["x-custom"], "v")
        XCTAssertEqual(MockURLProtocol.capturedHeaders["x-api-key"], "test-key")
    }

    /// The same header rides the catalogue path (`models.provider(_).list()`).
    func testCustomHeaderReachesCatalogueRequest() async throws {
        let body = #"{"data":[{"id":"gpt-5","object":"model","created":1715367049,"owned_by":"system"}]}"#
        MockURLProtocol.responseBody = Data(body.utf8)
        let client = Client(provider: .openai, apiKey: "test-key", session: MockURLProtocol.makeSession())
            .baseURL("https://mock.test")
            .addHeader("X-Custom", "v")

        let models = try await client.models.provider(.openai).list()

        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(MockURLProtocol.capturedHeaders["x-custom"], "v")
        // Bearer auth on the catalogue request is intact.
        XCTAssertEqual(MockURLProtocol.capturedHeaders["authorization"], "Bearer test-key")
    }

    /// A caller header whose name collides case-insensitively with the provider
    /// auth header is skipped — the SDK auth header is never clobbered (CCM-004).
    func testCaseInsensitiveCollisionDoesNotClobberAuth() async throws {
        MockURLProtocol.responseBody = Data("{}".utf8)
        let client = Client(provider: .anthropic, apiKey: "test-key", session: MockURLProtocol.makeSession())
            .addHeader("X-API-KEY", "attacker-value")

        _ = try await client.text.model("claude-sonnet-4-6").maxTokens(16).prompt("hello")

        // The provider auth value survives; the colliding caller header is dropped.
        XCTAssertEqual(MockURLProtocol.capturedHeaders["x-api-key"], "test-key")
    }
}
