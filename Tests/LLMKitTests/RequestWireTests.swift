import XCTest
@testable import LLMKit

/// Request-wire driver (ADR-028 direction): build an OpenAI chat request through
/// the full SDK stack, capture the outbound bytes via the injected mock session,
/// and assert the request body. Swift-local this slice — full cross-SDK PER_SDK
/// enrollment is the phase-2 exit gate.
final class RequestWireTests: XCTestCase {
    func testOpenAIChatBasicRequestBody() async throws {
        MockURLProtocol.reset()
        // A canned 200 lets prompt() complete; its content is irrelevant to the
        // request-side assertion.
        MockURLProtocol.responseBody = try Data(contentsOf: TestPaths.testdata("wire/response/v1/bodies/chat-openai.json"))
        MockURLProtocol.responseStatusCode = 200

        let client = Client.openai(apiKey: "sk-test-key", session: MockURLProtocol.makeSession())
        _ = try await client.text
            .model("gpt-4o")
            .maxTokens(256)
            .prompt("Reply with the single word: pong.")

        let capturedData = try XCTUnwrap(MockURLProtocol.capturedBody)
        let capturedText = try XCTUnwrap(String(data: capturedData, encoding: .utf8))
        let capturedJSON = try JSONValue.parse(capturedText)

        try TestPaths.writeRequestArtifact(fixture: "chat-openai-basic", body: capturedJSON)

        let expected = JSONValue.object([
            ("model", .string("gpt-4o")),
            ("max_tokens", .int(256)),
            ("messages", .array([
                .object([
                    ("role", .string("user")),
                    ("content", .string("Reply with the single word: pong.")),
                ]),
            ])),
        ])

        XCTAssertEqual(capturedJSON, expected)
    }
}
