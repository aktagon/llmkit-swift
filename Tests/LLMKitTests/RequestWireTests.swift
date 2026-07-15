import XCTest
@testable import LLMKit

/// Request-wire driver (ADR-028 direction): build each ChatCompletion request
/// through the full SDK stack, capture the outbound bytes via the injected mock
/// session, and assert the body is value-equal to the SAME shared golden at
/// codegen/testdata/wire/request/v1/<fixture>.json that the other four SDKs
/// assert. Each test also drops target/wire/request/<fixture>/swift.json so the
/// cross-SDK comparator (codegen/test_cross_sdk_request_wire.py) can enroll
/// Swift. Inputs are the SAME canonical values the other drivers feed (single-
/// sourced in ontology/wire-fixtures.ttl; hand-mirrored here — test drivers are
/// never generated). Phase 2 = ChatCompletion; media Parts / tools / batch /
/// SigV4 / media capabilities are driven in later phases.
final class RequestWireTests: XCTestCase {
    private func client(_ provider: ProviderName) -> Client {
        MockURLProtocol.reset()
        MockURLProtocol.responseBody = Data("{}".utf8)
        MockURLProtocol.responseStatusCode = 200
        return Client(provider: provider, apiKey: "key", session: MockURLProtocol.makeSession())
    }

    private func capturedBody() throws -> JSONValue {
        let data = try XCTUnwrap(MockURLProtocol.capturedBody)
        return try JSONValue.parse(String(decoding: data, as: UTF8.self))
    }

    private func assertGolden(_ fixture: String, _ body: JSONValue) throws {
        try TestPaths.writeRequestArtifact(fixture: fixture, body: body)
        let goldenText = try String(
            contentsOf: TestPaths.testdata("wire/request/v1/\(fixture).json"), encoding: .utf8
        )
        XCTAssertEqual(body, try JSONValue.parse(goldenText), "\(fixture) body differs from shared golden")
    }

    // MARK: - Options (one per model family; the double-serialization surface)

    func testOptionsOpenAIGPT4O() async throws {
        _ = try await client(.openai).text
            .model("gpt-4o").maxTokens(256).temperature(0.7).topP(0.9)
            .stopSequences(["END_OF_LIST"]).seed(42).frequencyPenalty(0.25).presencePenalty(0.15)
            .prompt("List three primary colors, then write END_OF_LIST.")
        try assertGolden("options-openai-gpt4o", try capturedBody())
    }

    func testOptionsOpenAIGPT5() async throws {
        _ = try await client(.openai).text
            .model("gpt-5").maxTokens(1024).reasoningEffort("low").seed(42)
            .prompt("Summarize the plot of Hamlet in two sentences.")
        try assertGolden("options-openai-gpt5", try capturedBody())
    }

    func testOptionsOpenAIOSeries() async throws {
        _ = try await client(.openai).text
            .model("o4-mini").maxTokens(1024).reasoningEffort("medium").seed(7)
            .prompt("What is the capital of Finland?")
        try assertGolden("options-openai-o-series", try capturedBody())
    }

    func testOptionsAnthropic() async throws {
        _ = try await client(.anthropic).text
            .model("claude-sonnet-4-6").maxTokens(2048).thinkingBudget(1024).stopSequences(["END_OF_ANSWER"])
            .prompt("Explain in one sentence why the sky appears blue at noon, then write END_OF_ANSWER.")
        try assertGolden("options-anthropic", try capturedBody())
    }

    func testOptionsAnthropicAdaptive() async throws {
        _ = try await client(.anthropic).text
            .model("claude-opus-4-7").maxTokens(2048).reasoningEffort("medium").stopSequences(["END_OF_ANSWER"])
            .prompt("State the boiling point of water at sea level in Celsius, then write END_OF_ANSWER.")
        try assertGolden("options-anthropic-adaptive", try capturedBody())
    }

    func testOptionsAnthropicPlain() async throws {
        _ = try await client(.anthropic).text
            .model("claude-sonnet-4-6").maxTokens(1024).temperature(0.7).topK(40).stopSequences(["END_OF_ANSWER"])
            .prompt("Name the longest river in Finland, then write END_OF_ANSWER.")
        try assertGolden("options-anthropic-plain", try capturedBody())
    }

    func testOptionsGoogle() async throws {
        _ = try await client(.google).text
            .model("gemini-3.5-flash").maxTokens(1024).temperature(0.7).topP(0.9).topK(40)
            .stopSequences(["END_OF_ANSWER"]).seed(7).reasoningEffort("low")
            .safetySettings([SafetySetting(category: "HARM_CATEGORY_DANGEROUS_CONTENT", threshold: "BLOCK_ONLY_HIGH")])
            .prompt("Name the two largest moons of Jupiter, then write END_OF_ANSWER.")
        try assertGolden("options-google", try capturedBody())
    }

    func testOptionsGoogleGemini25() async throws {
        _ = try await client(.google).text
            .model("gemini-2.5-flash").maxTokens(1024).temperature(0.5).thinkingBudget(512)
            .prompt("How many planets orbit the Sun? Answer with a number.")
        try assertGolden("options-google-gemini25", try capturedBody())
    }

    // MARK: - OpenAI-compat fleet

    func testWorkersAI() async throws {
        _ = try await client(.workersai).baseURL("https://mock.local/v1").text
            .model("@cf/meta/llama-3.1-8b-instruct").maxTokens(512).temperature(0.7).topP(0.9)
            .prompt("List three primary colors as a comma-separated list.")
        try assertGolden("workersai", try capturedBody())
    }

    // MARK: - Responses protocol (ADR-055)

    func testResponsesOpenAI() async throws {
        _ = try await client(.openai).text
            .protocol("responses").model("gpt-4o-mini").maxTokens(256)
            .prompt("Name the capital of Finland in one word.")
        try assertGolden("responses-openai", try capturedBody())
    }

    // MARK: - Structured output (schema normalization)

    private static let schemaFlat =
        "{\"type\":\"object\",\"properties\":{\"color\":{\"type\":\"string\"}},\"additionalProperties\":false}"
    private static let schemaNested =
        "{\"type\":\"object\",\"properties\":{\"residence\":{\"type\":\"object\",\"properties\":{\"addresses\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}},\"additionalProperties\":false}}},\"additionalProperties\":false}},\"additionalProperties\":false}"
    private let promptFlat = "What color is a clear daytime sky?"
    private let promptNested =
        "Name a coastal city in Finland where a harbor pilot might reside. Reply as structured data."

    func testStructuredOutputOpenAI() async throws {
        _ = try await client(.openai).text
            .model("gpt-4o-2024-08-06").schema(Self.schemaFlat).prompt(promptFlat)
        try assertGolden("structured-output-openai", try capturedBody())
    }

    func testStructuredOutputGoogle() async throws {
        _ = try await client(.google).text.schema(Self.schemaFlat).prompt(promptFlat)
        try assertGolden("structured-output-google", try capturedBody())
    }

    func testStructuredOutputAnthropic() async throws {
        _ = try await client(.anthropic).text
            .model("claude-sonnet-4-6").schema(Self.schemaFlat).prompt(promptFlat)
        try assertGolden("structured-output-anthropic", try capturedBody())
        // Load-bearing headers: without the structured-output beta Anthropic
        // 400s on output_format. Golden-locked across all four SDKs via the
        // companion structured-output-anthropic.headers.json.
        XCTAssertEqual(MockURLProtocol.capturedHeaders["anthropic-beta"], "structured-outputs-2025-11-13")
        try TestPaths.writeRequestHeaders(fixture: "structured-output-anthropic", headers: MockURLProtocol.capturedHeaders)
    }

    func testStructuredOutputNestedOpenAI() async throws {
        _ = try await client(.openai).text
            .model("gpt-4o-2024-08-06").schema(Self.schemaNested).prompt(promptNested)
        try assertGolden("structured-output-nested-openai", try capturedBody())
    }

    func testStructuredOutputNestedGoogle() async throws {
        _ = try await client(.google).text.schema(Self.schemaNested).prompt(promptNested)
        try assertGolden("structured-output-nested-google", try capturedBody())
    }

    func testStructuredOutputNestedAnthropic() async throws {
        _ = try await client(.anthropic).text
            .model("claude-sonnet-4-6").schema(Self.schemaNested).prompt(promptNested)
        try assertGolden("structured-output-nested-anthropic", try capturedBody())
    }
}
