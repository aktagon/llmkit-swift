import XCTest
@testable import LLMKit

///
///
///
final class CachingRuntimeTests: XCTestCase {
    private func mockClient() -> Client {
        Client(provider: .google, apiKey: "key", session: MockURLProtocol.makeSession())
    }

    private static let created = "{\"name\":\"cachedContents/abc123\"}"
    private static let answer =
        "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"Helsinki\"}]},\"finishReason\":\"STOP\"}],"
        + "\"usageMetadata\":{\"promptTokenCount\":3,\"candidatesTokenCount\":1}}"

    func testTextCacheTtlDrivesResourceCacheCreateBody() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.responseSequence = [Data(Self.created.utf8), Data(Self.answer.utf8)]

        let resp = try await mockClient().text
            .model("gemini-2.5-pro")
            .system("You are a terse geography assistant.")
            .caching()
            .cacheTtl(450)
            .prompt("Capital of Finland?")

        XCTAssertEqual(resp.text, "Helsinki")
        XCTAssertEqual(MockURLProtocol.capturedURLs.count, 2)
        XCTAssertTrue(
            MockURLProtocol.capturedURLs[0].contains("/v1beta/cachedContents"),
            "first hop must be the cache create, got \(MockURLProtocol.capturedURLs[0])"
        )
        let createBody = try JSONValue.parse(
            String(decoding: XCTUnwrap(MockURLProtocol.capturedBodies.first), as: UTF8.self)
        )
        XCTAssertEqual(createBody.stringValue(at: "ttl"), "450s")
        let mainBody = try JSONValue.parse(
            String(decoding: XCTUnwrap(MockURLProtocol.capturedBodies.last), as: UTF8.self)
        )
        XCTAssertEqual(mainBody.stringValue(at: "cachedContent"), "cachedContents/abc123")
    }

    func testAgentCacheTtlDrivesResourceCacheCreateBody() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.responseSequence = [Data(Self.created.utf8), Data(Self.answer.utf8)]

        let resp = try await mockClient().agent()
            .model("gemini-2.5-pro")
            .system("You are a terse geography assistant.")
            .caching()
            .cacheTtl(600)
            .prompt("Capital of Finland?")

        XCTAssertEqual(resp.text, "Helsinki")
        let createBody = try JSONValue.parse(
            String(decoding: XCTUnwrap(MockURLProtocol.capturedBodies.first), as: UTF8.self)
        )
        XCTAssertEqual(createBody.stringValue(at: "ttl"), "600s")
    }
}
