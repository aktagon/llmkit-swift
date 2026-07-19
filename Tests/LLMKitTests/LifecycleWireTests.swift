import XCTest
@testable import LLMKit

///
///
///
///
///
///
final class LifecycleWireTests: XCTestCase {
    ///
    ///
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
        //
        //
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
        //
        //
        MockURLProtocol.reset()
        MockURLProtocol.responseSequence = [Data("{\"id\":\"batch_1\",\"status\":\"failed\"}".utf8)]
        let status = try await batchJob().poll()
        try assertGolden("batch-failed", status)
    }
}
