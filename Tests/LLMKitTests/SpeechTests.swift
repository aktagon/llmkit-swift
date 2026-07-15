import XCTest
@testable import LLMKit

/// Mock-server unit tests for the speech-generation capability (`Speech.swift`).
/// Each response-parse test drives the real `client.speech.generate(...)` path
/// against a canned provider reply and asserts `actual == expected` on the
/// decoded `SpeechResponse`, exercising both audio encodings
/// (`base64Envelope` / `rawBody`) selected by the generated
/// `speechGenConfig(provider).audioResponseEncoding` — never provider name. The
/// request-body and validation cells complete the port coverage.
final class SpeechTests: XCTestCase {
    /// A real 44-byte WAV header (base64), the same clip the response-wire
    /// golden anchors — decodes to exactly 44 bytes.
    private static let wavBase64 = "UklGRiQAAABXQVZFZm10IBAAAAABAAEAgD4AAAB9AAACABAAZGF0YQAAAAA="

    private func client(_ provider: ProviderName, response: Data) -> Client {
        MockURLProtocol.reset()
        MockURLProtocol.responseBody = response
        MockURLProtocol.responseStatusCode = 200
        return Client(provider: provider, apiKey: "key", session: MockURLProtocol.makeSession())
    }

    private func capturedBody() throws -> JSONValue {
        try JSONValue.parse(String(decoding: try XCTUnwrap(MockURLProtocol.capturedBody), as: UTF8.self))
    }

    // MARK: - Response parsing (base64Envelope shape — Inworld)

    func testInworldBase64EnvelopeDecodes() async throws {
        let envelope = """
        {"audioContent":"\(Self.wavBase64)","usage":{"processedCharactersCount":18}}
        """
        let resp = try await client(.inworld, response: Data(envelope.utf8)).speech
            .model("inworld-tts-2").voice("Dennis")
            .generate("Hello from llmkit.")

        XCTAssertEqual(resp.audio.mimeType, "audio/wav")
        XCTAssertEqual(resp.audio.bytes, [UInt8](try XCTUnwrap(Data(base64Encoded: Self.wavBase64))))
        XCTAssertEqual(resp.audio.bytes.count, 44)
        // ADR-049 OQ-3: processedCharactersCount is not surfaced (no characters axis).
        XCTAssertEqual(resp.usage, Usage())
        XCTAssertEqual(resp.finishReason, "")
    }

    func testInworldEmptyAudioContentYieldsNoBytes() async throws {
        let resp = try await client(.inworld, response: Data("{\"audioContent\":\"\"}".utf8)).speech
            .model("inworld-tts-2").voice("Alex")
            .generate("silence")

        XCTAssertEqual(resp.audio.mimeType, "audio/wav")
        XCTAssertTrue(resp.audio.bytes.isEmpty)
    }

    // MARK: - Response parsing (rawBody shape — OpenAI)

    func testOpenAIRawBodyTakesResponseVerbatim() async throws {
        // OpenAI /v1/audio/speech returns binary audio, not JSON — the reply is
        // the audio bytes verbatim.
        let mp3: [UInt8] = [0xFF, 0xFB, 0x90, 0x00, 0x6D, 0x70, 0x33]
        let resp = try await client(.openai, response: Data(mp3)).speech
            .model("gpt-4o-mini-tts").voice("alloy")
            .generate("Hello from llmkit.")

        XCTAssertEqual(resp.audio.mimeType, "audio/mpeg")
        XCTAssertEqual(resp.audio.bytes, mp3)
        XCTAssertEqual(resp.usage, Usage())
    }

    // MARK: - Request bodies (per wire shape)

    func testInworldRequestBody() async throws {
        _ = try await client(.inworld, response: Data("{\"audioContent\":\"\"}".utf8)).speech
            .model("inworld-tts-2").voice("Dennis")
            .generate("Hello from llmkit.")

        XCTAssertEqual(try capturedBody(), .object([
            ("text", .string("Hello from llmkit.")),
            ("voiceId", .string("Dennis")),
            ("modelId", .string("inworld-tts-2")),
            ("audioConfig", .object([
                ("audioEncoding", .string("LINEAR16")),
                ("sampleRateHertz", .int(22050)),
            ])),
            ("deliveryMode", .string("BALANCED")),
        ]))
        // Inworld authenticates with a Basic-prefixed Authorization header.
        XCTAssertEqual(MockURLProtocol.capturedHeaders["authorization"], "Basic key")
    }

    func testOpenAIRequestBody() async throws {
        _ = try await client(.openai, response: Data([0xFF])).speech
            .model("gpt-4o-mini-tts").voice("alloy")
            .generate("Hello from llmkit.")

        XCTAssertEqual(try capturedBody(), .object([
            ("model", .string("gpt-4o-mini-tts")),
            ("input", .string("Hello from llmkit.")),
            ("voice", .string("alloy")),
            ("response_format", .string("mp3")),
        ]))
    }

    // MARK: - Validation

    func testRequiresModel() async throws {
        do {
            _ = try await client(.inworld, response: Data("{}".utf8)).speech
                .voice("Dennis").generate("hi")
            XCTFail("expected a validation error")
        } catch let LLMKitError.validation(field, _) {
            XCTAssertEqual(field, "model")
        }
    }

    func testRequiresText() async throws {
        do {
            _ = try await client(.inworld, response: Data("{}".utf8)).speech
                .model("inworld-tts-2").voice("Dennis").generate("")
            XCTFail("expected a validation error")
        } catch let LLMKitError.validation(field, _) {
            XCTAssertEqual(field, "text")
        }
    }

    func testRequiresVoice() async throws {
        do {
            _ = try await client(.inworld, response: Data("{}".utf8)).speech
                .model("inworld-tts-2").generate("hi")
            XCTFail("expected a validation error")
        } catch let LLMKitError.validation(field, _) {
            XCTAssertEqual(field, "voice")
        }
    }

    func testRejectsUnknownVoice() async throws {
        do {
            _ = try await client(.inworld, response: Data("{}".utf8)).speech
                .model("inworld-tts-2").voice("Nonexistent").generate("hi")
            XCTFail("expected a validation error")
        } catch let LLMKitError.validation(field, _) {
            XCTAssertEqual(field, "voice")
        }
    }

    func testRejectsUnknownModel() async throws {
        do {
            _ = try await client(.inworld, response: Data("{}".utf8)).speech
                .model("inworld-tts-9").voice("Dennis").generate("hi")
            XCTFail("expected a validation error")
        } catch let LLMKitError.validation(field, _) {
            XCTAssertEqual(field, "model")
        }
    }

    func testRejectsProviderWithoutSpeech() async throws {
        do {
            _ = try await client(.anthropic, response: Data("{}".utf8)).speech
                .model("inworld-tts-2").voice("Dennis").generate("hi")
            XCTFail("expected a validation error")
        } catch let LLMKitError.validation(field, _) {
            XCTAssertEqual(field, "provider")
        }
    }
}
