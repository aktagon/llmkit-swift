import XCTest
@testable import LLMKit

/// Behavior tests for the Phase-3 execution modes beyond the wire goldens: the
/// full agent tool loop (request -> tool call -> tool run -> follow-up request ->
/// text) and the batch submit+wait round-trip (multipart upload -> create ->
/// poll -> result). Real domain values, `actual == expected`.
final class ExecutionModeTests: XCTestCase {
    private func mockClient(_ provider: ProviderName) -> Client {
        Client(provider: provider, apiKey: "key", session: MockURLProtocol.makeSession())
    }

    // MARK: - Agent tool loop

    func testAgentRunsToolThenAnswers() async throws {
        MockURLProtocol.reset()
        // Turn 1: the model asks to call get_weather; turn 2: it answers.
        let toolCall = "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"tool_calls\":[{\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"get_weather\",\"arguments\":\"{\\\"city\\\":\\\"Helsinki\\\"}\"}}]}}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":5}}"
        let answer = "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"It is sunny in Helsinki.\"}}],\"usage\":{\"prompt_tokens\":8,\"completion_tokens\":6}}"
        MockURLProtocol.responseSequence = [Data(toolCall.utf8), Data(answer.utf8)]

        var receivedCity = ""
        let tool = Tool(
            name: "get_weather",
            description: "Get the current weather for a city.",
            schema: try JSONValue.parse("{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}}}"),
            run: { args in
                receivedCity = args.stringValue(at: "city")
                return "sunny, 21C"
            }
        )

        let response = try await mockClient(.openai).agent().addTool(tool).prompt("What is the weather in Helsinki?")

        XCTAssertEqual(response.text, "It is sunny in Helsinki.")
        // Usage accumulates across both turns.
        XCTAssertEqual(response.usage.input, 18)
        XCTAssertEqual(response.usage.output, 11)
        // The tool actually ran with the model-supplied argument.
        XCTAssertEqual(receivedCity, "Helsinki")

        // The follow-up (second) request carried the tool result back.
        let secondBody = try JSONValue.parse(String(decoding: XCTUnwrap(MockURLProtocol.capturedBody), as: UTF8.self))
        guard case let .array(messages)? = secondBody.member("messages") else {
            return XCTFail("second request has no messages array")
        }
        let toolResult = messages.first { $0.stringValue(at: "role") == "tool" }
        XCTAssertEqual(toolResult?.stringValue(at: "content"), "sunny, 21C")
        XCTAssertEqual(toolResult?.stringValue(at: "tool_call_id"), "call_1")
    }

    // MARK: - Batch submit + wait round-trip

    func testBatchSubmitAndWait() async throws {
        MockURLProtocol.reset()
        let resultLine = "{\"custom_id\":\"req-0\",\"response\":{\"body\":{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"Helsinki\"}}],\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":1}}}}"
        MockURLProtocol.responseSequence = [
            Data("{\"id\":\"file-in-1\"}".utf8),                                  // multipart upload
            Data("{\"id\":\"batch_1\"}".utf8),                                    // create batch
            Data("{\"id\":\"batch_1\",\"status\":\"completed\",\"output_file_id\":\"file-out-1\"}".utf8),  // poll
            Data(resultLine.utf8),                                               // result file content
        ]

        let job = try await mockClient(.openai).text.model("gpt-4o-mini").batch("What is the capital of Finland?")
        XCTAssertEqual(job.handle.id, "batch_1")

        let responses = try await job.wait()
        XCTAssertEqual(responses.count, 1)
        XCTAssertEqual(responses.first?.text, "Helsinki")
        XCTAssertEqual(responses.first?.usage.input, 3)
        XCTAssertEqual(responses.first?.usage.output, 1)
    }
}
