import XCTest
@testable import LLMKit

/// Mock-server unit tests for the music-generation capability (`Music.swift`).
/// There is no cross-SDK wire golden for music, so parity is held by these
/// unit tests (mirroring Rust's `music.rs` tests). Each drives the real
/// `client.music.generate(...)` path against a canned provider reply and
/// asserts `actual == expected` on the request body and the decoded
/// `MusicResponse`, exercising all three wire shapes (`MusicMinimax` /
/// `MusicPredict` / `MusicGenerateContent`) selected by the generated
/// `musicGenConfig(provider).wireShape` — never provider name.
final class MusicTests: XCTestCase {
    /// A short fake MP3 the MiniMax hex path round-trips (matches the Rust
    /// fixture `FAKE_MP3`).
    private static let fakeMP3: [UInt8] = [0xFF, 0xFB, 0x90, 0x00, 0x6D, 0x70, 0x33]
    /// A real 44-byte WAV header (base64) for the Vertex/Gemini base64 paths.
    private static let wavBase64 = "UklGRiQAAABXQVZFZm10IBAAAAABAAEAgD4AAAB9AAACABAAZGF0YQAAAAA="

    private func client(_ provider: ProviderName, response: String) -> Client {
        MockURLProtocol.reset()
        MockURLProtocol.responseBody = Data(response.utf8)
        MockURLProtocol.responseStatusCode = 200
        return Client(provider: provider, apiKey: "key", session: MockURLProtocol.makeSession())
            .baseURL("https://mock.local")
    }

    private func capturedBody() throws -> JSONValue {
        try JSONValue.parse(String(decoding: try XCTUnwrap(MockURLProtocol.capturedBody), as: UTF8.self))
    }

    private static func hexEncode(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - MiniMax (MusicMinimax shape: hex audio)

    func testMinimaxBodyPromptOnlyOmitsLyrics() async throws {
        _ = try await client(.minimax, response: "{\"data\":{\"audio\":\"\"}}").music
            .model("music-2.6").generate("lofi hip hop")

        XCTAssertEqual(try capturedBody(), .object([
            ("model", .string("music-2.6")),
            ("prompt", .string("lofi hip hop")),
            ("output_format", .string("hex")),
            ("audio_setting", .object([
                ("sample_rate", .int(44100)),
                ("bitrate", .int(128000)),
                ("format", .string("mp3")),
            ])),
        ]))
    }

    func testMinimaxBodyLyricsPartBuildsLyricsField() async throws {
        _ = try await client(.minimax, response: "{\"data\":{\"audio\":\"\"}}").music
            .model("music-2.6").text("pop ballad").lyrics("[chorus] hold on").generate("")

        let body = try capturedBody()
        XCTAssertEqual(body.member("prompt"), .string("pop ballad"))
        XCTAssertEqual(body.member("lyrics"), .string("[chorus] hold on"))
    }

    func testMinimaxResponseHexRoundTripsWithConfigMime() async throws {
        let response = """
        {"data":{"audio":"\(Self.hexEncode(Self.fakeMP3))"},\
        "base_resp":{"status_code":0,"status_msg":"success"}}
        """
        let resp = try await client(.minimax, response: response).music
            .model("music-2.6").generate("lofi hip hop")

        XCTAssertEqual(resp.audio.count, 1)
        XCTAssertEqual(resp.audio[0].bytes, Self.fakeMP3)
        XCTAssertEqual(resp.audio[0].mimeType, "audio/mpeg")
        // status_msg "success" is not surfaced as a finish message.
        XCTAssertEqual(resp.finishMessage, "")
    }

    func testMinimaxResponseSurfacesNonSuccessStatusMsg() async throws {
        let response = """
        {"data":{"audio":""},"base_resp":{"status_code":1004,"status_msg":"invalid api key"}}
        """
        let resp = try await client(.minimax, response: response).music
            .model("music-2.6").generate("lofi hip hop")

        XCTAssertEqual(resp.audio.count, 0)
        XCTAssertEqual(resp.finishMessage, "invalid api key")
    }

    // MARK: - Vertex (MusicPredict shape: instances/parameters, base64 audio)

    func testVertexBodyAndResponse() async throws {
        let response = """
        {"predictions":[{"audioContent":"\(Self.wavBase64)","mimeType":"audio/wav"}]}
        """
        let resp = try await client(.vertex, response: response).music
            .model("lyria-002").generate("ambient soundscape")

        XCTAssertEqual(try capturedBody(), .object([
            ("instances", .array([.object([("prompt", .string("ambient soundscape"))])])),
            ("parameters", .object([("sampleCount", .int(1))])),
        ]))
        XCTAssertEqual(resp.audio.count, 1)
        XCTAssertEqual(resp.audio[0].mimeType, "audio/wav")
        XCTAssertEqual(resp.audio[0].bytes.count, 44)
    }

    func testVertexFoldsLyricsIntoPrompt() async throws {
        _ = try await client(.vertex, response: "{\"predictions\":[]}").music
            .model("lyria-002").lyrics("hum along").generate("gentle piece")

        // Lyria 2 has no lyrics wire-slot; lyrics fold into the prompt text.
        XCTAssertEqual(
            try capturedBody().lookup("instances[0].prompt"),
            .string("gentle piece\nhum along")
        )
    }

    // MARK: - Gemini (MusicGenerateContent shape: contents/parts, base64 audio)

    func testGeminiBodyAndResponse() async throws {
        let response = """
        {"candidates":[{"finishReason":"STOP","content":{"parts":[\
        {"text":"la la la"},\
        {"inlineData":{"mimeType":"audio/mpeg","data":"\(Self.wavBase64)"}}]}}]}
        """
        let resp = try await client(.google, response: response).music
            .model("lyria-3-pro-preview").generate("an upbeat melody")

        XCTAssertEqual(
            try capturedBody(),
            .object([
                ("contents", .array([.object([("parts", .array([
                    .object([("text", .string("an upbeat melody"))]),
                ]))])])),
                ("generationConfig", .object([("responseModalities", .array([.string("AUDIO")]))])),
            ])
        )
        XCTAssertEqual(resp.audio.count, 1)
        XCTAssertEqual(resp.audio[0].mimeType, "audio/mpeg")
        XCTAssertEqual(resp.text, "la la la")
        XCTAssertEqual(resp.finishReason, "STOP")
    }

    // MARK: - Raw opt-in + middleware

    func testRawOptInPopulatesRaw() async throws {
        let response = """
        {"data":{"audio":"\(Self.hexEncode(Self.fakeMP3))"},"base_resp":{"status_code":0,"status_msg":"success"}}
        """
        let resp = try await client(.minimax, response: response).music
            .model("music-2.6").raw().generate("lofi hip hop")

        XCTAssertNotNil(resp.raw)
        XCTAssertEqual(resp.raw?.lookup("base_resp.status_code"), .int(0))
    }

    func testMiddlewareFiresPreAndPost() async throws {
        let response = """
        {"data":{"audio":"\(Self.hexEncode(Self.fakeMP3))"},"base_resp":{"status_code":0,"status_msg":"success"}}
        """
        actor Recorder {
            var ops: [MiddlewarePhase] = []
            func record(_ phase: MiddlewarePhase) { ops.append(phase) }
        }
        let recorder = Recorder()
        _ = try await client(.minimax, response: response).music
            .model("music-2.6")
            .addMiddleware { event in
                Task { await recorder.record(event.phase) }
                return nil
            }
            .generate("lofi hip hop")
        // Give the detached record tasks a moment to land.
        try await Task.sleep(nanoseconds: 20_000_000)
        let ops = await recorder.ops
        XCTAssertTrue(ops.contains(.pre))
        XCTAssertTrue(ops.contains(.post))
    }

    func testMiddlewarePreVetoAborts() async throws {
        struct Denied: Error {}
        do {
            _ = try await client(.minimax, response: "{}").music
                .model("music-2.6")
                .addMiddleware { _ in Denied() }
                .generate("lofi hip hop")
            XCTFail("expected a veto")
        } catch is MiddlewareVeto {
            // expected
        }
    }

    // MARK: - Validation

    func testRequiresModel() async throws {
        do {
            _ = try await client(.minimax, response: "{}").music.generate("a song")
            XCTFail("expected a validation error")
        } catch let LLMKitError.validation(field, _) {
            XCTAssertEqual(field, "model")
        }
    }

    func testRejectsBothEmpty() async throws {
        do {
            _ = try await client(.minimax, response: "{}").music.model("music-2.6").generate("")
            XCTFail("expected a validation error")
        } catch let LLMKitError.validation(field, _) {
            XCTAssertEqual(field, "prompt")
        }
    }

    func testRejectsUnknownProvider() async throws {
        do {
            _ = try await client(.openai, response: "{}").music.model("whatever").generate("x")
            XCTFail("expected a validation error")
        } catch let LLMKitError.validation(field, _) {
            XCTAssertEqual(field, "provider")
        }
    }

    func testRejectsUnknownModel() async throws {
        do {
            _ = try await client(.minimax, response: "{}").music.model("music-9.9").generate("x")
            XCTFail("expected a validation error")
        } catch let LLMKitError.validation(field, _) {
            XCTAssertEqual(field, "model")
        }
    }
}
