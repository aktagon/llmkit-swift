import XCTest
@testable import LLMKit

///
///
///
final class ResponseParseTests: XCTestCase {
    func testOpenAIChatResponseMatchesSharedGolden() throws {
        let bodyData = try Data(contentsOf: TestPaths.testdata("wire/response/v1/bodies/chat-openai.json"))
        let config = providerConfig(.openai)
        let response = try ResponseParser.parse(config: config, body: bodyData)

        //
        //
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
