import XCTest
@testable import LLMKit

///
///
///
///
final class UploadTests: XCTestCase {
    override func setUp() { MockURLProtocol.reset() }

    private func client(_ provider: ProviderName) -> Client {
        Client(provider: provider, apiKey: "test-key", session: MockURLProtocol.makeSession())
    }

    ///
    private final class Recorder: @unchecked Sendable {
        var events: [Event] = []
        func record(_ event: Event) { events.append(event) }
    }

    func testUploadBytesParsesFileAndBuildsMultipart() async throws {
        MockURLProtocol.responseBody = Data(
            #

        let file = try await client(.anthropic)
            .upload()
            .bytes(Data("hello".utf8))
            .filename("notes.pdf")
            .run()

        //
        XCTAssertEqual(file.id, "file_abc123")
        XCTAssertEqual(file.name, "notes.pdf")
        XCTAssertEqual(file.mimeType, "application/pdf")

        //
        let body = String(decoding: try XCTUnwrap(MockURLProtocol.capturedBody), as: UTF8.self)
        XCTAssertTrue(body.contains(#"name="file"; filename="notes.pdf""#), "file part: \(body)")
        XCTAssertTrue(body.contains("Content-Type: application/pdf"), "detected mime: \(body)")
        XCTAssertTrue(body.contains("hello"), "payload present")

        //
        XCTAssertEqual(MockURLProtocol.capturedHeaders["anthropic-beta"], "files-api-2025-04-14")
        XCTAssertEqual(MockURLProtocol.capturedURLs.first, "https://api.anthropic.com/v1/files")
    }

    func testUploadPathDerivesFilename() async throws {
        MockURLProtocol.responseBody = Data(
            #

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("report.pdf")
        try Data("report bytes".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let file = try await client(.anthropic).upload().path(tmp.path).run()

        XCTAssertEqual(file.id, "file_xyz")
        let body = String(decoding: try XCTUnwrap(MockURLProtocol.capturedBody), as: UTF8.self)
        //
        XCTAssertTrue(body.contains(#"filename="report.pdf""#), body)
    }

    func testExtraFieldsPurposeForOpenAI() async throws {
        MockURLProtocol.responseBody = Data(#"{"id":"file_oai","filename":"data.jsonl"}"#.utf8)

        let file = try await client(.openai)
            .upload().bytes(Data("{}".utf8)).filename("data.jsonl").run()

        XCTAssertEqual(file.id, "file_oai")
        let body = String(decoding: try XCTUnwrap(MockURLProtocol.capturedBody), as: UTF8.self)
        //
        XCTAssertTrue(body.contains(#"name="purpose""#), body)
        XCTAssertTrue(body.contains("assistants"), body)
    }

    ///
    ///
    ///
    func testUploadHostileFilenameEscaped() async throws {
        MockURLProtocol.responseBody = Data(
            #
        let hostile = "evil\"name\\inject\r\nX-Fake: 1.mp3"

        _ = try await client(.anthropic)
            .upload().bytes(Data("audio-bytes".utf8)).filename(hostile).run()

        let body = String(decoding: try XCTUnwrap(MockURLProtocol.capturedBody), as: UTF8.self)
        XCTAssertTrue(
            body.contains(#"filename="evil\"name\\injectX-Fake: 1.mp3""#),
            "filename not escaped: \(body)")
        XCTAssertFalse(body.contains("\nX-Fake"), "raw CR/LF leaked: \(body)")
    }

    func testFiresUploadMiddleware() async throws {
        MockURLProtocol.responseBody = Data(#"{"id":"file_1","filename":"a.txt","mime_type":"text/plain"}"#.utf8)
        let recorder = Recorder()
        let hook: MiddlewareFn = { event in recorder.record(event); return nil }

        _ = try await client(.anthropic)
            .upload().addMiddleware(hook).bytes(Data("x".utf8)).filename("a.txt").run()

        XCTAssertEqual(recorder.events.count, 2)
        XCTAssertEqual(recorder.events[0].op, .upload)
        XCTAssertEqual(recorder.events[0].phase, .pre)
        XCTAssertEqual(recorder.events[0].provider, "anthropic")
        XCTAssertEqual(recorder.events[1].phase, .post)
        XCTAssertNil(recorder.events[1].err)
    }

    func testValidationRejectsBadInputs() async {
        //
        await assertThrowsValidation { try await self.client(.anthropic).upload().run() }
        //
        await assertThrowsValidation {
            try await self.client(.anthropic).upload()
                .path("/tmp/x").bytes(Data("y".utf8)).filename("y").run()
        }
        //
        await assertThrowsValidation {
            try await self.client(.anthropic).upload().bytes(Data("z".utf8)).run()
        }
    }

    func testUnsupportedProviderThrows() async {
        await assertThrowsValidation {
            try await self.client(.ollama).upload().bytes(Data("q".utf8)).filename("q.txt").run()
        }
    }

    private func assertThrowsValidation(
        _ block: @escaping () async throws -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            try await block()
            XCTFail("expected a validation error", file: file, line: line)
        } catch let error as LLMKitError {
            guard case .validation = error else {
                return XCTFail("expected .validation, got \(error)", file: file, line: line)
            }
        } catch {
            XCTFail("expected LLMKitError.validation, got \(error)", file: file, line: line)
        }
    }
}
