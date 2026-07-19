import XCTest
@testable import LLMKit

///
///
///
///
///
///
final class VideoTests: XCTestCase {
    private func mockClient(_ provider: ProviderName) -> Client {
        Client(provider: provider, apiKey: "key", session: MockURLProtocol.makeSession())
    }

    //

    func testGrokTextToVideoWaitReturnsURL() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.responseSequence = [
            Data(#"{"request_id":"vid_alpine"}"#.utf8),                                    // submit
            Data(#"{"status":"pending"}"#.utf8),                                           // poll: running
            Data(#"{"status":"done","video":{"url":"https://xai.example/vid_alpine.mp4","duration":6}}"#.utf8),  // poll: done
        ]
        let job = try await mockClient(.grok).video
            .model("grok-imagine-video")
            .submit("A drone shot sweeping over snow-capped alpine peaks at sunrise")
        XCTAssertEqual(job.handle.id, "vid_alpine")

        //
        let fast = job.cadence(interval: 0.01, timeout: 600)
        let response = try await fast.wait()
        XCTAssertEqual(response.videos.count, 1)
        XCTAssertEqual(response.videos.first?.url, "https://xai.example/vid_alpine.mp4")
        XCTAssertEqual(response.videos.first?.bytes, [])
        XCTAssertEqual(response.videos.first?.durationSeconds, 6)
        XCTAssertEqual(response.videos.first?.mimeType, "video/mp4")
    }

    ///
    func testGrokPollRunningThenSucceeded() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.responseSequence = [
            Data(#"{"request_id":"vid_1"}"#.utf8),
            Data(#"{"status":"processing"}"#.utf8),
            Data(#"{"status":"done","video":{"url":"https://xai.example/vid_1.mp4","duration":4}}"#.utf8),
        ]
        let job = try await mockClient(.grok).video.model("grok-imagine-video").submit("A city skyline at night")

        let first = try await job.poll()
        XCTAssertEqual(first.state, .running)
        XCTAssertEqual(first.rawStatus, "processing")
        XCTAssertNil(first.result)

        let second = try await job.poll()
        XCTAssertEqual(second.state, .succeeded)
        XCTAssertEqual(second.rawStatus, "done")
        XCTAssertEqual(second.result?.videos.first?.url, "https://xai.example/vid_1.mp4")
    }

    //

    func testGrokImageToVideoSubmitBodyCarriesSeedFrame() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.responseSequence = [
            Data(#"{"request_id":"vid_i2v"}"#.utf8),
            Data(#"{"status":"done","video":{"url":"https://xai.example/vid_i2v.mp4","duration":8}}"#.utf8),
        ]
        //
        let seed = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGM4YWQEAALyAS2saifrAAAAAElFTkSuQmCC"))
        let job = try await mockClient(.grok).video
            .model("grok-imagine-video")
            .image("image/png", seed)
            .submit("Animate the still: a slow cinematic push-in")

        //
        let submitBody = try JSONValue.parse(String(decoding: XCTUnwrap(MockURLProtocol.capturedBody), as: UTF8.self))
        XCTAssertEqual(submitBody.stringValue(at: "model"), "grok-imagine-video")
        XCTAssertTrue(submitBody.stringValue(at: "image.url").hasPrefix("data:image/png;base64,"))

        let fast = job.cadence(interval: 0.01, timeout: 600)
        let response = try await fast.wait()
        XCTAssertEqual(response.videos.first?.url, "https://xai.example/vid_i2v.mp4")
    }

    ///
    ///
    func testTextOnlyModelRejectsImageToVideo() async throws {
        MockURLProtocol.reset()
        let seed = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgo="))
        do {
            _ = try await mockClient(.zhipu).video
                .model("cogvideox-3").image("image/png", seed).submit("x")
            XCTFail("expected a validation error for image-to-video on a text-only model")
        } catch let LLMKitError.validation(field, message) {
            XCTAssertEqual(field, "parts")
            XCTAssertTrue(message.contains("text-to-video-only"))
        }
    }

    //

    func testGrokFailedPollThrows() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.responseSequence = [
            Data(#"{"request_id":"vid_bad"}"#.utf8),
            Data(#"{"status":"failed","error":{"code":"content_policy","message":"blocked by content policy"}}"#.utf8),
        ]
        let job = try await mockClient(.grok).video.model("grok-imagine-video").submit("something")
        let fast = job.cadence(interval: 0.01, timeout: 600)
        do {
            _ = try await fast.wait()
            XCTFail("expected a failure error from a failed video job")
        } catch let LLMKitError.unsupported(message) {
            XCTAssertTrue(message.contains("blocked by content policy"), "got: \(message)")
        }
    }

    //

    func testMiniMaxTwoHopResolvesDownloadURL() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.responseSequence = [
            Data(#"{"task_id":"mm_1"}"#.utf8),                                             // submit
            Data(#"{"status":"Processing"}"#.utf8),                                        // poll: running
            Data(#"{"status":"Success","file_id":"file_777"}"#.utf8),                      // poll: done (file ref)
            Data(#"{"file":{"download_url":"https://minimax.example/mm_1.mp4"}}"#.utf8),    // file-retrieve
        ]
        let job = try await mockClient(.minimax).video
            .model("MiniMax-Hailuo-2.3")
            .submit("A drone shot sweeping over snow-capped alpine peaks at sunrise")
        XCTAssertEqual(job.handle.id, "mm_1")

        let fast = job.cadence(interval: 0.01, timeout: 600)
        let response = try await fast.wait()
        XCTAssertEqual(response.videos.first?.url, "https://minimax.example/mm_1.mp4")
        XCTAssertEqual(response.videos.first?.bytes, [])
    }

    //

    func testPixVerseSubmitCarriesTraceAndAPIKeyHeaders() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.responseBody = Data(#"{"Resp":{"video_id":318633193768896}}"#.utf8)
        let job = try await mockClient(.pixverse).video
            .model("v4.5")
            .submit("A drone shot sweeping over snow-capped alpine peaks at sunrise")
        //
        XCTAssertEqual(job.handle.id, "318633193768896")
        //
        //
        XCTAssertEqual(MockURLProtocol.capturedHeaders["api-key"], "key")
        XCTAssertFalse((MockURLProtocol.capturedHeaders["ai-trace-id"] ?? "").isEmpty)
    }
}
