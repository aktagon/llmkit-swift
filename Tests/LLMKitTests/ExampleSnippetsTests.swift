import XCTest
import LLMKit

/// Executes the canonical README call chains against the mock transport, so the
/// snippets shown in `swift/README.md` are code that runs in CI. The
/// `// #region <name>` blocks are extracted verbatim into the README by
/// `codegen/render_readme.py` (include directives) — keep each region a pure
/// call chain that reads cleanly standalone: no client construction, no
/// assertions inside the region. Deliberately a plain `import LLMKit` (not
/// `@testable`): a snippet that compiles here is reachable by a real consumer.
final class ExampleSnippetsTests: XCTestCase {
    private func mockClient(_ provider: ProviderName) -> Client {
        Client(provider: provider, apiKey: "key", session: MockURLProtocol.makeSession())
    }

    private static func hexEncode(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Stream (README "Stream" fence)

    func testStreamSnippet() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.responseBody = try Data(
            contentsOf: TestPaths.testdata("wire/response/v1/bodies/stream-openai.sse"))
        let client = mockClient(.openai)

        // #region stream
        let resp = try await client.text
            .system("Be brief")
            .stream("Tell me a joke") { chunk in
                print(chunk, terminator: "")
            }

        print("\nUsage: \(resp.usage.input) in / \(resp.usage.output) out")
        // #endregion

        XCTAssertEqual(resp.text, "Hello.")
        XCTAssertEqual(resp.finishReason, "stop")
        XCTAssertEqual(resp.usage.input, 14)
        XCTAssertEqual(resp.usage.output, 2)
    }

    // MARK: - Batch (README "Batches" fence)

    func testBatchSnippet() async throws {
        MockURLProtocol.reset()
        let resultLines = """
        {"custom_id":"req-0","response":{"body":{"choices":[{"message":{"role":"assistant","content":"Bonjour"}}],"usage":{"prompt_tokens":5,"completion_tokens":1}}}}
        {"custom_id":"req-1","response":{"body":{"choices":[{"message":{"role":"assistant","content":"Hola"}}],"usage":{"prompt_tokens":5,"completion_tokens":1}}}}
        """
        MockURLProtocol.responseSequence = [
            Data("{\"id\":\"file-in-1\"}".utf8),
            Data("{\"id\":\"batch_ex1\"}".utf8),
            Data("{\"id\":\"batch_ex1\",\"status\":\"completed\",\"output_file_id\":\"file-out-1\"}".utf8),
            Data(resultLines.utf8),
        ]
        let client = mockClient(.openai)

        // #region batch
        let job = try await client.text
            .system("Be brief")
            .batch(
                "Translate hello to French",
                "Translate hello to Spanish"
            )
        let results = try await job.wait()
        for r in results { print(r.text) }
        // #endregion

        XCTAssertEqual(job.handle.id, "batch_ex1")
        XCTAssertEqual(results.map(\.text), ["Bonjour", "Hola"])
    }

    // MARK: - Music (README "Music" fence)

    func testMusicSnippet() async throws {
        MockURLProtocol.reset()
        let mp3: [UInt8] = [0x49, 0x44, 0x33, 0x04, 0x00]  // "ID3" tag header
        let body = "{\"data\":{\"audio\":\"\(Self.hexEncode(mp3))\"},"
            + "\"base_resp\":{\"status_code\":0,\"status_msg\":\"success\"}}"
        MockURLProtocol.responseBody = Data(body.utf8)
        let client = mockClient(.minimax)

        // #region music
        let resp = try await client.music
            .model("music-2.6")
            .generate("a calm instrumental, warm piano and soft strings")

        if let first = resp.audio.first {
            print("\(first.bytes.count) audio bytes (\(first.mimeType))")
        }
        // #endregion

        XCTAssertEqual(resp.audio.count, 1)
        XCTAssertEqual(resp.audio[0].bytes, mp3)
        XCTAssertEqual(resp.audio[0].mimeType, "audio/mpeg")
    }

    // MARK: - Video (README "Video" fence)

    func testVideoSnippet() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.responseSequence = [
            Data("{\"request_id\":\"vid_ex1\"}".utf8),
            Data("{\"status\":\"done\",\"video\":{\"url\":\"https://xai.example/vid_ex1.mp4\",\"duration\":6}}".utf8),
        ]
        let client = mockClient(.grok)

        // #region video
        let job = try await client.video
            .model("grok-imagine-video")
            .submit("a slow cinematic drone shot flying over snow-capped alpine peaks at golden hour")
        let resp = try await job.wait()

        if let first = resp.videos.first {
            print("url=\(first.url) duration=\(first.durationSeconds)s")
        }
        // #endregion

        XCTAssertEqual(resp.videos.count, 1)
        XCTAssertEqual(resp.videos.first?.url, "https://xai.example/vid_ex1.mp4")
        XCTAssertEqual(resp.videos.first?.durationSeconds, 6)
    }
}
