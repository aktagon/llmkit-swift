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

    // MARK: - Streaming (BUG-028: stream_options.include_usage on the body)

    func testStreamOpenAI() async throws {
        _ = try? await client(.openai).text.model("gpt-4o-mini").stream("Say hello.") { _ in }
        try assertGolden("stream-openai", try capturedBody())
    }

    // MARK: - Agent tool definitions (per wire shape)

    private static let toolSchema =
        "{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}},\"additionalProperties\":false}"
    private static let toolPrompt = "What is the weather in Helsinki right now?"

    private func weatherTool() throws -> Tool {
        Tool(
            name: "get_weather",
            description: "Get the current weather for a city.",
            schema: try JSONValue.parse(Self.toolSchema),
            run: { _ in "" }
        )
    }

    func testToolDefOpenAI() async throws {
        _ = try await client(.openai).agent().addTool(try weatherTool()).prompt(Self.toolPrompt)
        try assertGolden("tooldef-openai", try capturedBody())
    }

    func testToolDefAnthropic() async throws {
        _ = try await client(.anthropic).agent().addTool(try weatherTool()).prompt(Self.toolPrompt)
        try assertGolden("tooldef-anthropic", try capturedBody())
    }

    func testToolDefGoogle() async throws {
        _ = try await client(.google).agent().addTool(try weatherTool()).prompt(Self.toolPrompt)
        try assertGolden("tooldef-google", try capturedBody())
    }

    func testToolDefBedrock() async throws {
        withBedrockEnv()
        _ = try await client(.bedrock).agent().addTool(try weatherTool()).prompt(Self.toolPrompt)
        try assertGolden("tooldef-bedrock", try capturedBody())
    }

    // MARK: - Media Parts on the text path (ADR-060: vision image + file refs)

    /// The shared 1x1 PNG the other SDKs feed, decoded to bytes for `.image`.
    private static let imageBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGM4YWQEAALyAS2saifrAAAAAElFTkSuQmCC"
    private func imageBytes() throws -> Data { try XCTUnwrap(Data(base64Encoded: Self.imageBase64)) }

    func testOpenAITextImage() async throws {
        _ = try await client(.openai).text
            .model("gpt-4o").image("image/png", try imageBytes())
            .prompt("Describe the attached image in one sentence.")
        try assertGolden("openai-text-image", try capturedBody())
    }

    func testAnthropicTextImage() async throws {
        _ = try await client(.anthropic).text
            .model("claude-opus-4-8").image("image/png", try imageBytes())
            .prompt("Describe the attached image in one sentence.")
        try assertGolden("anthropic-text-image", try capturedBody())
    }

    func testGoogleTextImage() async throws {
        _ = try await client(.google).text
            .model("gemini-2.5-flash").image("image/png", try imageBytes())
            .prompt("Describe the attached image in one sentence.")
        try assertGolden("google-text-image", try capturedBody())
    }

    func testBedrockTextImage() async throws {
        withBedrockEnv()
        _ = try await client(.bedrock).text
            .model("anthropic.claude-sonnet-4-20250514-v1:0").image("image/png", try imageBytes())
            .prompt("Describe the attached image in one sentence.")
        try assertGolden("bedrock-text-image", try capturedBody())
    }

    func testOpenAITextDocument() async throws {
        _ = try await client(.openai).text
            .model("gpt-4o").file("file-9aXr2bQ7m1Tn")
            .prompt("Summarize the attached document in three sentences.")
        try assertGolden("openai-text-document", try capturedBody())
    }

    func testAnthropicTextDocument() async throws {
        _ = try await client(.anthropic).text
            .model("claude-opus-4-8").file("file_011CMZq8h5VnVe8jL3qK7p2R")
            .prompt("Summarize the attached document in three sentences.")
        try assertGolden("anthropic-text-document", try capturedBody())
        // BUG-017: a file-referencing Anthropic request must carry the files-api
        // beta; golden-locked across all SDKs via anthropic-text-document.headers.json.
        XCTAssertEqual(MockURLProtocol.capturedHeaders["anthropic-beta"], "files-api-2025-04-14")
        try TestPaths.writeRequestHeaders(fixture: "anthropic-text-document", headers: MockURLProtocol.capturedHeaders)
    }

    func testAnthropicSchemaDocument() async throws {
        let schema = "{\"type\":\"object\",\"properties\":{\"summary\":{\"type\":\"string\"}},\"additionalProperties\":false}"
        _ = try await client(.anthropic).text
            .model("claude-opus-4-8").schema(schema).file("file_011CMZq8h5VnVe8jL3qK7p2R")
            .prompt("Summarize the attached document as structured data.")
        try assertGolden("anthropic-schema-document", try capturedBody())
        // BUG-017 compose path: the structured-output beta and the files-api beta
        // compose into one comma-separated anthropic-beta, deduped.
        XCTAssertEqual(
            MockURLProtocol.capturedHeaders["anthropic-beta"],
            "structured-outputs-2025-11-13,files-api-2025-04-14"
        )
        try TestPaths.writeRequestHeaders(fixture: "anthropic-schema-document", headers: MockURLProtocol.capturedHeaders)
    }

    func testBatchMultimodalAnthropic() async throws {
        let c = client(.anthropic)
        MockURLProtocol.responseBody = Data("{\"id\":\"batch_1\"}".utf8)
        _ = try await c.text
            .model("claude-sonnet-4-6")
            .file("file_011CMZq8h5VnVe8jL3qK7p2R")
            .image("image/png", try imageBytes())
            .batch("Summarize the attached document and describe the image in one sentence.")
        try assertGolden("batch-multimodal-anthropic", try capturedBody())
        // The batch CREATE request lifts the per-item files-api beta (BUG-017).
        XCTAssertEqual(MockURLProtocol.capturedHeaders["anthropic-beta"], "files-api-2025-04-14")
        try TestPaths.writeRequestHeaders(fixture: "batch-multimodal-anthropic", headers: MockURLProtocol.capturedHeaders)
    }

    // MARK: - Caching (Anthropic explicit cache_control on the system prefix)

    private static let cachingSystem = "a long stable system prefix"
    private static let cachingPrompt = "hi"

    func testCachingTextAnthropic() async throws {
        _ = try await client(.anthropic).text
            .system(Self.cachingSystem).caching().prompt(Self.cachingPrompt)
        try assertGolden("caching-text-anthropic", try capturedBody())
    }

    func testCachingAgentAnthropic() async throws {
        _ = try await client(.anthropic).agent()
            .system(Self.cachingSystem).caching().prompt(Self.cachingPrompt)
        try assertGolden("caching-agent-anthropic", try capturedBody())
    }

    func testCachingBatchAnthropic() async throws {
        let c = client(.anthropic)
        // The batch CREATE response must carry an id so submit does not throw;
        // the assertion is on the captured CREATE request body, not the reply.
        MockURLProtocol.responseBody = Data("{\"id\":\"batch_1\"}".utf8)
        _ = try await c.text.system(Self.cachingSystem).caching().batch(Self.cachingPrompt)
        try assertGolden("caching-batch-anthropic", try capturedBody())
    }

    // MARK: - Image generation (JSON bodies only; multipart edits are a WIRE-008
    // documented exclusion). Inputs mirror the WIRE_IMAGE_* wire_inputs constants.

    func testImageGenGoogleFlash() async throws {
        _ = try await client(.google).image
            .model("gemini-3.1-flash-image-preview").aspectRatio("16:9").imageSize("2K")
            .generate("A lighthouse on a rocky coastline at dusk")
        try assertGolden("image-gen-google-flash", try capturedBody())
    }

    func testImageGenGooglePro() async throws {
        _ = try await client(.google).image
            .model("gemini-3-pro-image-preview").aspectRatio("4:3").imageSize("1K").includeText()
            .generate("A watercolor map of the Baltic Sea")
        try assertGolden("image-gen-google-pro", try capturedBody())
    }

    func testImageGenOpenAI() async throws {
        _ = try await client(.openai).image
            .model("gpt-image-2").imageSize("1024x1024").quality("low")
            .outputFormat("png").background("opaque").count(1)
            .generate("A minimalist line drawing of a sailboat")
        try assertGolden("image-gen-openai", try capturedBody())
    }

    func testImageGenRecraft() async throws {
        _ = try await client(.recraft).image
            .model("recraftv3").imageSize("1024x1024").count(1)
            .generate("A minimalist line drawing of a sailboat")
        try assertGolden("image-gen-recraft", try capturedBody())
    }

    func testImageEditGoogleFlash() async throws {
        let png = try XCTUnwrap(Data(base64Encoded: Self.imageBase64))
        _ = try await client(.google).image
            .model("gemini-3.1-flash-image-preview").image("image/png", png)
            .generate("Recolor the square to deep blue")
        try assertGolden("image-edit-google-flash", try capturedBody())
    }

    // MARK: - Speech generation (TTS). Inputs mirror the WIRE_SPEECH_* wire_inputs
    // constants; the two shapes are the flat-JSON Inworld body (Basic auth) and
    // the flat-JSON OpenAI body.

    func testSpeechInworld() async throws {
        _ = try await client(.inworld).speech
            .model("inworld-tts-2").voice("Dennis")
            .generate("Hello from llmkit.")
        try assertGolden("speech-inworld", try capturedBody())
    }

    func testSpeechOpenAI() async throws {
        _ = try await client(.openai).speech
            .model("gpt-4o-mini-tts").voice("alloy")
            .generate("Hello from llmkit.")
        try assertGolden("speech-openai", try capturedBody())
    }

    // MARK: - Bedrock Converse (SigV4 signing; body is asserted, signature is not)

    func testBedrockChat() async throws {
        withBedrockEnv()
        _ = try await client(.bedrock).text
            .maxTokens(256).temperature(0.7).topP(0.9).stopSequences(["END_OF_ANSWER"])
            .prompt("Name the capital of Finland in one word, then write END_OF_ANSWER.")
        try assertGolden("bedrock-chat", try capturedBody())
    }

    /// Bedrock SigV4 reads its region + secret key from the environment; the
    /// access key is the client api key. Deterministic dummy values — the
    /// signature is time-dependent and NOT asserted (only the body is).
    private func withBedrockEnv() {
        setenv("AWS_REGION", "us-east-1", 1)
        setenv("AWS_SECRET_ACCESS_KEY", "test-secret", 1)
        setenv("AWS_SESSION_TOKEN", "", 1)
    }
}
