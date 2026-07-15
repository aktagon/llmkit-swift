import XCTest
@testable import LLMKit

/// Behavior tests for the transcription capability (ADR-048 / ADR-051) beyond the
/// wire goldens: the OpenAI SYNCHRONOUS `transcribe` decode (text + segment
/// timing + the multipart body shape) and the AssemblyAI ASYNCHRONOUS submit ->
/// poll -> result lifecycle over the shared Job engine, driven by a scripted
/// `MockURLProtocol.responseSequence`. Real domain values, `actual == expected`.
final class TranscriptionTests: XCTestCase {
    private func mockClient(_ provider: ProviderName) -> Client {
        Client(provider: provider, apiKey: "key", session: MockURLProtocol.makeSession())
    }

    // MARK: - OpenAI synchronous transcribe (multipart POST -> transcript)

    func testOpenAITranscribeParsesTextAndSegments() async throws {
        MockURLProtocol.reset()
        // verbose_json: offsets are SECONDS (float) -> integer milliseconds.
        MockURLProtocol.responseBody = Data(#"""
        {"task":"transcribe","language":"english","duration":3.5,"text":"Turn left at the harbor.",
         "segments":[
            {"id":0,"start":0.0,"end":1.5,"text":"Turn left"},
            {"id":1,"start":1.5,"end":3.5,"text":" at the harbor."}
         ]}
        """#.utf8)
        let response = try await mockClient(.openai).transcription
            .model("whisper-1")
            .transcribe([Part.audioBytes(mimeType: "audio/mpeg", data: Data("fake-audio".utf8))])

        XCTAssertEqual(response.text, "Turn left at the harbor.")
        XCTAssertEqual(response.segments.count, 2)
        XCTAssertEqual(response.segments[0], TranscriptSegment(text: "Turn left", start: 0, end: 1500, speaker: ""))
        XCTAssertEqual(response.segments[1], TranscriptSegment(text: " at the harbor.", start: 1500, end: 3500, speaker: ""))
        // AssemblyAI-style token axis is absent for OpenAI TTS -> usage stays zero.
        XCTAssertEqual(response.usage, Usage())
    }

    /// The captured request is a multipart/form-data body carrying the model,
    /// response_format, and the audio file part with its real mime + extension —
    /// decoded here via the same descriptor decoder the wire driver asserts.
    func testOpenAITranscribeMultipartBodyShape() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.responseBody = Data(#"{"text":"ok"}"#.utf8)
        _ = try await mockClient(.openai).transcription
            .model("whisper-1")
            .transcribe([Part.audioBytes(mimeType: "audio/mpeg", data: Data("fake-audio".utf8))])

        let contentType = try XCTUnwrap(MockURLProtocol.capturedHeaders["content-type"])
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
        let descriptor = RequestWireTests.multipartToDescriptor(
            body: try XCTUnwrap(MockURLProtocol.capturedBody), contentType: contentType
        )
        let expected = JSONValue.object([
            ("_encoding", .string("multipart/form-data")),
            ("fields", .array([
                .object([("name", .string("model")), ("value", .string("whisper-1"))]),
                .object([("name", .string("response_format")), ("value", .string("verbose_json"))]),
                .object([
                    ("name", .string("file")),
                    ("filename", .string("audio.mp3")),
                    ("contentType", .string("audio/mpeg")),
                    ("bytes", .string("<audio-bytes>")),
                ]),
            ])),
        ])
        XCTAssertEqual(descriptor, expected)
    }

    /// The sync path ingests inline bytes only — a remote audio URL is rejected
    /// pre-flight (OAA-005, the inverse of AssemblyAI).
    func testOpenAITranscribeRejectsRemoteURL() async throws {
        MockURLProtocol.reset()
        do {
            _ = try await mockClient(.openai).transcription
                .model("whisper-1")
                .transcribe([Part.audio(url: "https://storage.example.com/clip.mp3")])
            XCTFail("expected a validation error for a remote URL on the sync path")
        } catch let LLMKitError.validation(field, message) {
            XCTAssertEqual(field, "parts")
            XCTAssertTrue(message.contains("inline audio bytes only"), "got: \(message)")
        }
    }

    /// `transcribe` on an asynchronous provider names the right terminal (OAA-003).
    func testTranscribeOnAsyncProviderRejects() async throws {
        do {
            _ = try await mockClient(.assemblyai).transcription
                .model("best")
                .transcribe([Part.audioBytes(mimeType: "audio/mpeg", data: Data("x".utf8))])
            XCTFail("expected a validation error using transcribe on an async provider")
        } catch let LLMKitError.validation(field, message) {
            XCTAssertEqual(field, "interaction")
            XCTAssertTrue(message.contains("use submit"), "got: \(message)")
        }
    }

    // MARK: - AssemblyAI asynchronous submit -> poll -> result lifecycle

    func testAssemblyAISubmitWaitReturnsTranscript() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.responseSequence = [
            Data(#"{"id":"transcript_abc123"}"#.utf8),                                       // submit
            Data(#"{"status":"queued"}"#.utf8),                                              // poll: running
            Data(#"{"status":"processing"}"#.utf8),                                          // poll: running
            Data(#"""
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

        // The captured submit body is the {audio_url} JSON body.
        let submitBody = try JSONValue.parse(String(decoding: XCTUnwrap(MockURLProtocol.capturedBody), as: UTF8.self))
        XCTAssertEqual(submitBody, .object([("audio_url", .string("https://storage.example.com/meeting-2026-06-24.mp3"))]))

        job.interval = 0.01 // shrink the inter-poll sleep for the test
        let response = try await job.wait()
        XCTAssertEqual(response.text, "Turn left at the harbor.")
        XCTAssertEqual(response.segments.count, 2)
        XCTAssertEqual(response.segments[0], TranscriptSegment(text: "Turn", start: 120, end: 360, speaker: "A"))
        XCTAssertEqual(response.segments[1], TranscriptSegment(text: "left", start: 360, end: 560, speaker: "A"))
        XCTAssertEqual(response.usage, Usage())
    }

    /// The `poll()` primitive (ADR-063): one round-trip -> a normalized status,
    /// running then succeeded, safe on a reconstituted handle (cross-process).
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

    /// A status=error transcript surfaces as an error (never a silent empty
    /// success); the provider error message rides through on `error`.
    func testAssemblyAIFailedPollThrows() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.responseSequence = [
            Data(#"{"id":"transcript_bad"}"#.utf8),
            Data(#"{"status":"error","error":"audio file could not be decoded"}"#.utf8),
        ]
        let job = try await mockClient(.assemblyai).transcription
            .submit([Part.audio(url: "https://storage.example.com/broken.mp3")])
        job.interval = 0.01
        do {
            _ = try await job.wait()
            XCTFail("expected a failure error from a failed transcription job")
        } catch let LLMKitError.unsupported(message) {
            XCTAssertTrue(message.contains("audio file could not be decoded"), "got: \(message)")
        }
    }

    /// `submit` on a synchronous provider names the right terminal (OAA-003).
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

    /// Exactly one audio part is required (STT-003) — a non-audio part is rejected.
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
