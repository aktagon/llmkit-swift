import XCTest
@testable import LLMKit

///
///
///
///
///
final class TranscriptionTests: XCTestCase {
    private func mockClient(_ provider: ProviderName) -> Client {
        Client(provider: provider, apiKey: "key", session: MockURLProtocol.makeSession())
    }

    //

    func testOpenAITranscribeParsesTextAndSegments() async throws {
        MockURLProtocol.reset()
        //
        MockURLProtocol.responseBody = Data(#"""
        {"task":"transcribe","language":"english","duration":3.5,"text":"Turn left at the harbor.",
         "segments":[
            {"id":0,"start":0.0,"end":1.5,"text":"Turn left"},
            {"id":1,"start":1.5,"end":3.5,"text":" at the harbor."}
         ]}
        """















































































"""
            {"status":"completed","text":"Turn left at the harbor.","words":[
               {"text":"Turn","start":120,"end":360,"speaker":"A"},
               {"text":"left","start":360,"end":560,"speaker":"A"}
            ]}
            """#.utf8),                                                                       // poll: done
        ]
        let job = try await mockClient(.assemblyai).transcription
            .submit([Part.audio(url: "https://storage.example.com/meeting-2026-06-24.mp3")])
        XCTAssertEqual(job.handle.id, "transcript_abc123")
        XCTAssertEqual(job.handle.provider, .assemblyai)

        //
        let submitBody = try JSONValue.parse(String(decoding: XCTUnwrap(MockURLProtocol.capturedBody), as: UTF8.self))
        XCTAssertEqual(submitBody, .object([("audio_url", .string("https://storage.example.com/meeting-2026-06-24.mp3"))]))

        //
        let fast = job.cadence(interval: 0.01, timeout: 600)
        let response = try await fast.wait()
        XCTAssertEqual(response.text, "Turn left at the harbor.")
        XCTAssertEqual(response.segments.count, 2)
        XCTAssertEqual(response.segments[0], TranscriptSegment(text: "Turn", start: 120, end: 360, speaker: "A"))
        XCTAssertEqual(response.segments[1], TranscriptSegment(text: "left", start: 360, end: 560, speaker: "A"))
        XCTAssertEqual(response.usage, Usage())
    }

    ///
    ///
    func testAssemblyAIPollRunningThenSucceeded() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.responseSequence = [
            Data(#"{"id":"transcript_p1"}"#.utf8),
            Data(#"{"status":"processing"}"#.utf8),
            Data(#"{"status":"completed","text":"Done.","words":[]}"#.utf8),
        ]
        let job = try await mockClient(.assemblyai).transcription
            .submit([Part.audio(url: "https://storage.example.com/clip.mp3")])

        let first = try await job.poll()
        XCTAssertEqual(first.state, .running)
        XCTAssertEqual(first.rawStatus, "processing")
        XCTAssertNil(first.result)

        let second = try await job.poll()
        XCTAssertEqual(second.state, .succeeded)
        XCTAssertEqual(second.rawStatus, "completed")
        XCTAssertEqual(second.result?.text, "Done.")
        XCTAssertEqual(second.result?.segments, [])
    }

    ///
    ///
    func testAssemblyAIFailedPollThrows() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.responseSequence = [
            Data(#"{"id":"transcript_bad"}"#.utf8),
            Data(#"{"status":"error","error":"audio file could not be decoded"}"#.utf8),
        ]
        let job = try await mockClient(.assemblyai).transcription
            .submit([Part.audio(url: "https://storage.example.com/broken.mp3")])
        let fast = job.cadence(interval: 0.01, timeout: 600)
        do {
            _ = try await fast.wait()
            XCTFail("expected a failure error from a failed transcription job")
        } catch let LLMKitError.unsupported(message) {
            XCTAssertTrue(message.contains("audio file could not be decoded"), "got: \(message)")
        }
    }

    ///
    func testSubmitOnSyncProviderRejects() async throws {
        do {
            _ = try await mockClient(.openai).transcription
                .submit([Part.audioBytes(mimeType: "audio/mpeg", data: Data("x".utf8))])
            XCTFail("expected a validation error using submit on a sync provider")
        } catch let LLMKitError.validation(field, message) {
            XCTAssertEqual(field, "interaction")
            XCTAssertTrue(message.contains("use transcribe"), "got: \(message)")
        }
    }

    ///
    func testRejectsNonAudioPart() async throws {
        do {
            _ = try await mockClient(.assemblyai).transcription.submit([Part.text("transcribe this")])
            XCTFail("expected a validation error for a non-audio part")
        } catch let LLMKitError.validation(field, message) {
            XCTAssertEqual(field, "parts")
            XCTAssertTrue(message.contains("only audio parts"), "got: \(message)")
        }
    }
}
