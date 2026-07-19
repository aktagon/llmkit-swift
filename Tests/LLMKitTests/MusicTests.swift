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
final class MusicTests: XCTestCase {
    ///
    ///
    private static let fakeMP3: [UInt8] = [0xFF, 0xFB, 0x90, 0x00, 0x6D, 0x70, 0x33]
    ///
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

    //

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











"""
        {"data":{"audio":""},"base_resp":{"status_code":1004,"status_msg":"invalid api key"}}
        """










"""
        {"predictions":[{"audioContent":"\(Self.wavBase64)","mimeType":"audio/wav"}]}
        """


























"""
        {"candidates":[{"finishReason":"STOP","content":{"parts":[\
        {"text":"la la la"},\
        {"inlineData":{"mimeType":"audio/mpeg","data":"\(Self.wavBase64)"}}]}}]}
        """





















"""
        {"data":{"audio":"\(Self.hexEncode(Self.fakeMP3))"},"base_resp":{"status_code":0,"status_msg":"success"}}
        """








"""
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
        //
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
            //
        }
    }

    //

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
