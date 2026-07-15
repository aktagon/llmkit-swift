import XCTest
@testable import LLMKit

/// Cross-SDK LIFECYCLE conformance (ADR-062 slice 1). The INBOUND counterpart to
/// the request-wire suite: given the same provider poll response, every SDK's Job
/// engine must normalize it to the SAME terminal JobStatus. Drives one
/// `BatchJob.poll()` round-trip against a scripted mock and drops the normalized
/// `{state, hasResult, rawStatus, cause}` projection to
/// `target/wire/lifecycle/<fixture>/swift.json`, value-equal to the shared golden.
final class LifecycleWireTests: XCTestCase {
    /// An OpenAI batch job (id "batch_1") pointed at the mock transport — mirror
    /// of the Rust driver's `openai_batch_handle`.
    private func batchJob() -> BatchJob {
        BatchJob(
            handle: BatchHandle(id: "batch_1", provider: .openai, raw: false),
            apiKey: "test-key",
            http: HTTPClient(session: MockURLProtocol.makeSession()),
            baseURLOverride: nil
        )
    }

    private func assertGolden(_ fixture: String, _ status: JobStatus<[Response]>) throws {
        let cause: JSONValue = status.cause.map {
            .object([("status", .string($0.status)), ("timedOut", .bool($0.timedOut))])
        } ?? .null
        let projection = JSONValue.object([
            ("state", .string(status.state.description)),
            ("hasResult", .bool(status.result != nil)),
            ("rawStatus", .string(status.rawStatus)),
            ("cause", cause),
        ])
        try TestPaths.writeLifecycleArtifact(fixture: fixture, projection: projection)
        let goldenText = try String(
            contentsOf: TestPaths.testdata("wire/lifecycle/v1/\(fixture).json"), encoding: .utf8
        )
        XCTAssertEqual(projection, try JSONValue.parse(goldenText), "\(fixture) differs from shared golden")
    }

    func testBatchSucceeded() async throws {
        // Two-hop: the status GET reports completed + output_file_id, then the
        // file-content GET returns one JSONL result line (OpenAI response.body).
        let jsonl = "{\"custom_id\":\"req-0\",\"response\":{\"body\":{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"ok\"}}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1}}}}"
        MockURLProtocol.reset()
        MockURLProtocol.responseSequence = [
            Data("{\"id\":\"batch_1\",\"status\":\"completed\",\"output_file_id\":\"file-out-1\"}".utf8),
            Data(jsonl.utf8),
        ]
        let status = try await batchJob().poll()
        try assertGolden("batch-succeeded", status)
    }

    func testBatchFailed() async throws {
        // The status GET reports failed and there is no output_file_id — one
        // round-trip, no result fetch.
        MockURLProtocol.reset()
        MockURLProtocol.responseSequence = [Data("{\"id\":\"batch_1\",\"status\":\"failed\"}".utf8)]
        let status = try await batchJob().poll()
        try assertGolden("batch-failed", status)
    }
}
