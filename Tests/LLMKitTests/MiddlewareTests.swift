import XCTest
@testable import LLMKit

///
///
///
///
final class MiddlewareTests: XCTestCase {
    ///
    ///
    private final class Recorder: @unchecked Sendable {
        var events: [Event] = []
        func record(_ event: Event) { events.append(event) }
    }

    private func client(_ provider: ProviderName, response: String) -> Client {
        MockURLProtocol.reset()
        MockURLProtocol.responseBody = Data(response.utf8)
        MockURLProtocol.responseStatusCode = 200
        return Client(provider: provider, apiKey: "key", session: MockURLProtocol.makeSession())
    }

    private static let chatResponse =
        "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"Helsinki\"}}]," +
        "\"usage\":{\"prompt_tokens\":7,\"completion_tokens\":2}}"

    //

    func testPromptFiresLlmRequestPreAndPost() async throws {
        let recorder = Recorder()
        let hook: MiddlewareFn = { event in recorder.record(event); return nil }

        let response = try await client(.openai, response: Self.chatResponse).text
            .model("gpt-4o-mini").addMiddleware(hook)
            .prompt("What is the capital of Finland?")

        XCTAssertEqual(response.text, "Helsinki")
        XCTAssertEqual(recorder.events.count, 2)
        //
        XCTAssertEqual(recorder.events[0].op, .llmRequest)
        XCTAssertEqual(recorder.events[0].phase, .pre)
        XCTAssertEqual(recorder.events[0].provider, "openai")
        XCTAssertEqual(recorder.events[0].model, "gpt-4o-mini")
        XCTAssertNil(recorder.events[0].usage)
        XCTAssertEqual(recorder.events[1].phase, .post)
        XCTAssertEqual(recorder.events[1].usage?.input, 7)
        XCTAssertEqual(recorder.events[1].usage?.output, 2)
        XCTAssertNil(recorder.events[1].err)
    }

    //

    private struct BlockedError: Error, Equatable { let reason: String }

    func testPreVetoAbortsPrompt() async throws {
        let recorder = Recorder()
        let veto: MiddlewareFn = { _ in BlockedError(reason: "policy") }
        let observer: MiddlewareFn = { event in recorder.record(event); return nil }

        do {
            _ = try await client(.openai, response: Self.chatResponse).text
                .model("gpt-4o-mini").addMiddleware(veto).addMiddleware(observer)
                .prompt("This must not reach the provider.")
            XCTFail("veto should have thrown")
        } catch let error as MiddlewareVeto {
            XCTAssertEqual(error.cause as? BlockedError, BlockedError(reason: "policy"))
        }
        //
        //
        XCTAssertTrue(recorder.events.isEmpty)
        XCTAssertNil(MockURLProtocol.capturedBody)
    }

    //

    func testAgentFiresToolCall() async throws {
        MockURLProtocol.reset()
        let toolCall =
            "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"tool_calls\":[{\"id\":\"call_1\"," +
            "\"type\":\"function\",\"function\":{\"name\":\"get_weather\"," +
            "\"arguments\":\"{\\\"city\\\":\\\"Helsinki\\\"}\"}}]}}],\"usage\":{\"prompt_tokens\":9,\"completion_tokens\":4}}"
        let answer =
            "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"It is sunny.\"}}]," +
            "\"usage\":{\"prompt_tokens\":6,\"completion_tokens\":3}}"
        MockURLProtocol.responseSequence = [Data(toolCall.utf8), Data(answer.utf8)]

        let recorder = Recorder()
        let hook: MiddlewareFn = { event in recorder.record(event); return nil }
        let tool = Tool(
            name: "get_weather",
            description: "Get the current weather for a city.",
            schema: try JSONValue.parse("{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}}}"),
            run: { _ in "sunny, 21C" }
        )

        let client = Client(provider: .openai, apiKey: "key", session: MockURLProtocol.makeSession())
        _ = try await client.agent().addTool(tool).addMiddleware(hook).prompt("Weather in Helsinki?")

        //
        let toolPre = recorder.events.first { $0.op == .toolCall && $0.phase == .pre }
        let toolPost = recorder.events.first { $0.op == .toolCall && $0.phase == .post }
        XCTAssertEqual(toolPre?.tool, "get_weather")
        XCTAssertEqual(toolPre?.args["city"], .string("Helsinki"))
        XCTAssertEqual(toolPost?.result, "sunny, 21C")
        XCTAssertTrue(recorder.events.contains { $0.op == .llmRequest && $0.phase == .post })
    }

    //

    func testBatchFiresBatchSubmit() async throws {
        let recorder = Recorder()
        let hook: MiddlewareFn = { event in recorder.record(event); return nil }
        let c = client(.anthropic, response: "{\"id\":\"batch_1\"}")

        _ = try await c.text.model("claude-sonnet-4-6").addMiddleware(hook).batch("q1")

        let pre = recorder.events.first { $0.op == .batchSubmit && $0.phase == .pre }
        let post = recorder.events.first { $0.op == .batchSubmit && $0.phase == .post }
        XCTAssertNotNil(pre)
        XCTAssertEqual(pre?.provider, "anthropic")
        XCTAssertNotNil(post)
        XCTAssertNil(post?.err)
    }
}
