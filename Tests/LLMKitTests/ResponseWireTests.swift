import XCTest
@testable import LLMKit

///
///
///
///
///
///
///
///
final class ResponseWireTests: XCTestCase {
    private func drive(shape: String, provider: ProviderName) async throws {
        let body = try Data(contentsOf: TestPaths.testdata("wire/response/v1/bodies/\(shape).json"))
        MockURLProtocol.reset()
        MockURLProtocol.responseBody = body
        MockURLProtocol.responseStatusCode = 200

        let client = Client(provider: provider, apiKey: "key", session: MockURLProtocol.makeSession())
        let response = try await client.text.prompt("ping")

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

        try TestPaths.writeResponseArtifact(shape: shape, projection: projection)
        let goldenText = try String(
            contentsOf: TestPaths.testdata("wire/response/v1/\(shape).json"), encoding: .utf8
        )
        XCTAssertEqual(projection, try JSONValue.parse(goldenText), "\(shape) projection differs from shared golden")
    }

    func testChatOpenAI() async throws { try await drive(shape: "chat-openai", provider: .openai) }
    func testChatAnthropic() async throws { try await drive(shape: "chat-anthropic", provider: .anthropic) }
    func testChatGoogle() async throws { try await drive(shape: "chat-google", provider: .google) }

    ///
    ///
    ///
    private func driveStream(shape: String, provider: ProviderName) async throws {
        let body = try Data(contentsOf: TestPaths.testdata("wire/response/v1/bodies/\(shape).sse"))
        MockURLProtocol.reset()
        MockURLProtocol.responseBody = body
        MockURLProtocol.responseStatusCode = 200

        let client = Client(provider: provider, apiKey: "key", session: MockURLProtocol.makeSession())
        let response = try await client.text.stream("ping") { _ in }

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

        try TestPaths.writeResponseArtifact(shape: shape, projection: projection)
        let goldenText = try String(
            contentsOf: TestPaths.testdata("wire/response/v1/\(shape).json"), encoding: .utf8
        )
        XCTAssertEqual(projection, try JSONValue.parse(goldenText), "\(shape) projection differs from shared golden")
    }

    func testStreamOpenAI() async throws { try await driveStream(shape: "stream-openai", provider: .openai) }
    func testStreamGoogle() async throws { try await driveStream(shape: "stream-google", provider: .google) }

    ///
    ///
    ///
    ///
    private func driveImage(shape: String, provider: ProviderName, model: String) async throws {
        let body = try Data(contentsOf: TestPaths.testdata("wire/response/v1/bodies/\(shape).json"))
        MockURLProtocol.reset()
        MockURLProtocol.responseBody = body
        MockURLProtocol.responseStatusCode = 200

        let client = Client(provider: provider, apiKey: "key", session: MockURLProtocol.makeSession())
            .baseURL("https://mock.local")
        let response = try await client.image.model(model).generate("a cat")

        let first = response.images.first
        let projection = JSONValue.object([
            ("content", .object([
                ("byteLen", .int(Int64(first?.bytes.count ?? 0))),
                ("count", .int(Int64(response.images.count))),
                ("kind", .string("image")),
                ("mimeType", .string(first?.mimeType ?? "")),
            ])),
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

        try TestPaths.writeResponseArtifact(shape: shape, projection: projection)
        let goldenText = try String(
            contentsOf: TestPaths.testdata("wire/response/v1/\(shape).json"), encoding: .utf8
        )
        XCTAssertEqual(projection, try JSONValue.parse(goldenText), "\(shape) projection differs from shared golden")
    }

    func testImageGoogle() async throws {
        try await driveImage(shape: "image-google", provider: .google, model: "gemini-3.1-flash-image-preview")
    }

    func testImageOpenAI() async throws {
        try await driveImage(shape: "image-openai", provider: .openai, model: "gpt-image-1")
    }

    func testImageVertex() async throws {
        try await driveImage(shape: "image-vertex", provider: .vertex, model: "imagen-3.0-generate-002")
    }

    ///
    ///
    ///
    ///
    ///
    private func driveSpeech(
        shape: String, provider: ProviderName, model: String, voice: String
    ) async throws {
        let body = try Data(contentsOf: TestPaths.testdata("wire/response/v1/bodies/\(shape).json"))
        MockURLProtocol.reset()
        MockURLProtocol.responseBody = body
        MockURLProtocol.responseStatusCode = 200

        let client = Client(provider: provider, apiKey: "key", session: MockURLProtocol.makeSession())
        let response = try await client.speech.model(model).voice(voice).generate("ping")

        let projection = JSONValue.object([
            ("content", .object([
                ("byteLen", .int(Int64(response.audio.bytes.count))),
                ("kind", .string("speech")),
                ("mimeType", .string(response.audio.mimeType)),
            ])),
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

        try TestPaths.writeResponseArtifact(shape: shape, projection: projection)
        let goldenText = try String(
            contentsOf: TestPaths.testdata("wire/response/v1/\(shape).json"), encoding: .utf8
        )
        XCTAssertEqual(projection, try JSONValue.parse(goldenText), "\(shape) projection differs from shared golden")
    }

    func testSpeechInworld() async throws {
        try await driveSpeech(shape: "speech-inworld", provider: .inworld, model: "inworld-tts-2", voice: "Dennis")
    }

    ///
    ///
    ///
    ///
    ///
    private func driveTranscription(shape: String, provider: ProviderName, model: String) async throws {
        let body = try Data(contentsOf: TestPaths.testdata("wire/response/v1/bodies/\(shape).json"))
        MockURLProtocol.reset()
        MockURLProtocol.responseBody = body
        MockURLProtocol.responseStatusCode = 200

        let client = Client(provider: provider, apiKey: "key", session: MockURLProtocol.makeSession())
        let response = try await client.transcription
            .model(model)
            .transcribe([Part.audioBytes(mimeType: "audio/mpeg", data: Data("fake-audio".utf8))])

        let projection = JSONValue.object([
            ("content", .object([
                ("kind", .string("transcript")),
                ("segments", .int(Int64(response.segments.count))),
                ("text", .string(response.text)),
            ])),
            ("error", .null),
            ("finishReason", .string("")),
            ("usage", .object([
                ("cacheRead", .int(Int64(response.usage.cacheRead))),
                ("cacheWrite", .int(Int64(response.usage.cacheWrite))),
                ("cost", .double(response.usage.cost)),
                ("input", .int(Int64(response.usage.input))),
                ("output", .int(Int64(response.usage.output))),
                ("reasoning", .int(Int64(response.usage.reasoning))),
            ])),
        ])

        try TestPaths.writeResponseArtifact(shape: shape, projection: projection)
        let goldenText = try String(
            contentsOf: TestPaths.testdata("wire/response/v1/\(shape).json"), encoding: .utf8
        )
        XCTAssertEqual(projection, try JSONValue.parse(goldenText), "\(shape) projection differs from shared golden")
    }

    func testTranscriptionOpenAI() async throws {
        try await driveTranscription(shape: "transcription-openai", provider: .openai, model: "whisper-1")
    }

    ///
    ///
    ///
    ///
    ///
    ///
    ///
    ///
    ///
    private func driveModels(shape: String, parse: (Data) throws -> ParsedModelsPage) throws {
        let body = try Data(contentsOf: TestPaths.testdata("wire/response/v1/bodies/\(shape).json"))
        let page = try parse(body)
        let first = page.records.first

        let projection = JSONValue.object([
            ("content", .object([
                ("count", .int(Int64(page.records.count))),
                ("first", .object([
                    ("contextWindow", .int(Int64(first?.contextWindow ?? 0))),
                    ("displayName", .string(first?.displayName ?? "")),
                    ("maxOutput", .int(Int64(first?.maxOutput ?? 0))),
                ])),
                ("firstId", .string(first?.id ?? "")),
                ("kind", .string("models")),
                ("lastId", .string(page.records.last?.id ?? "")),
                ("nextCursor", .string(page.nextCursor)),
            ])),
            ("error", .null),
        ])

        try TestPaths.writeResponseArtifact(shape: shape, projection: projection)
        let goldenText = try String(
            contentsOf: TestPaths.testdata("wire/response/v1/\(shape).json"), encoding: .utf8
        )
        XCTAssertEqual(projection, try JSONValue.parse(goldenText), "\(shape) projection differs from shared golden")
    }

    func testModelsAnthropic() throws {
        try driveModels(shape: "models-anthropic", parse: parseAnthropicModelsResponse)
    }

    func testModelsOpenAI() throws {
        try driveModels(shape: "models-openai", parse: parseOpenAICohortModelsResponse)
    }

    func testModelsGoogle() throws {
        try driveModels(shape: "models-google", parse: parseGoogleModelsResponse)
    }

    ///
    ///
    ///
    ///
    ///
    ///
    ///
    ///
    ///
    ///
    private func batchResultsArtifact(_ responses: [Response]) -> JSONValue {
        let first: JSONValue
        if let r = responses.first {
            first = .object([
                ("finishReason", .string(r.finishReason)),
                ("text", .string(r.text)),
                ("usage", .object([
                    ("cacheRead", .int(Int64(r.usage.cacheRead))),
                    ("cacheWrite", .int(Int64(r.usage.cacheWrite))),
                    ("cost", .double(r.usage.cost)),
                    ("input", .int(Int64(r.usage.input))),
                    ("output", .int(Int64(r.usage.output))),
                    ("reasoning", .int(Int64(r.usage.reasoning))),
                ])),
            ])
        } else {
            first = .object([])
        }
        return .object([
            ("content", .object([
                ("count", .int(Int64(responses.count))),
                ("first", first),
                ("kind", .string("batch_results")),
            ])),
            ("error", .null),
        ])
    }

    func testBatchResultsAnthropic() async throws {
        let results = try Data(
            contentsOf: TestPaths.testdata("wire/response/v1/bodies/batch-results-anthropic.jsonl")
        )
        MockURLProtocol.reset()
        MockURLProtocol.responseSequence = [
            Data("{\"id\":\"batch_1\",\"processing_status\":\"ended\"}".utf8),
            results,
        ]
        let job = BatchJob(
            handle: BatchHandle(id: "batch_1", provider: .anthropic, raw: false),
            apiKey: "test-key",
            http: HTTPClient(session: MockURLProtocol.makeSession()),
            baseURLOverride: nil
        )
        let status = try await job.poll()
        guard let responses = status.result else {
            XCTFail("expected a succeeded result, got \(status.state)")
            return
        }
        let projection = batchResultsArtifact(responses)
        try TestPaths.writeResponseArtifact(shape: "batch-results-anthropic", projection: projection)
        let goldenText = try String(
            contentsOf: TestPaths.testdata("wire/response/v1/batch-results-anthropic.json"), encoding: .utf8
        )
        XCTAssertEqual(
            projection,
            try JSONValue.parse(goldenText),
            "batch-results-anthropic projection differs from shared golden"
        )
    }
}
