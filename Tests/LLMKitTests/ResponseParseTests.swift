import XCTest
@testable import LLMKit

/// Response-wire parse test (ADR-065 direction): feed the live-anchored OpenAI
/// chat body into the Swift parser and assert the projection equals the shared
/// cross-SDK golden.
final class ResponseParseTests: XCTestCase {
    func testOpenAIChatResponseMatchesSharedGolden() throws {
        let bodyData = try Data(contentsOf: TestPaths.testdata("wire/response/v1/bodies/chat-openai.json"))
        let config = providerConfig(.openai)
        let response = try ResponseParser.parse(config: config, body: bodyData)

        // Project the typed Response onto the golden's shape (content/error/
        // finishReason/usage), then compare value-equal to the shared golden.
        let projection = JSONValue.object([
            ("content", .string(response.text)),
            ("error", .null),
            ("finishReason", .string(response.finishReason)),
            ("usage", .object([
                ("cacheRead", .int(Int64(response.usage.cacheRead))),
                ("cacheWrite", .int(Int64(response.usage.cacheWrite))),
                ("cost", .double(response.usage.cost)),
                ("input", .int(Int64(response.usage.input))),
                ("output", .int(Int64(response.usage.output))),
                ("reasoning", .int(Int64(response.usage.reasoning))),
            ])),
        ])

        let goldenText = try String(contentsOf: TestPaths.testdata("wire/response/v1/chat-openai.json"), encoding: .utf8)
        let golden = try JSONValue.parse(goldenText)

        XCTAssertEqual(projection, golden)
    }
}
