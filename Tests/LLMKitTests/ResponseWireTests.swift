import XCTest
@testable import LLMKit

/// Response-wire driver (ADR-065 direction): feed each anchored provider reply
/// (codegen/testdata/wire/response/v1/bodies/<shape>.json) through the real
/// public prompt path against a mock server, then normalize the typed Response
/// to the SAME projection the other four SDKs assert — {content, error,
/// finishReason, usage{...}} — dropping target/wire/response/<shape>/swift.json
/// for the cross-SDK comparator (codegen/test_cross_sdk_response.py). Phase 2 =
/// the three ChatCompletion shapes; media / stream / transcription shapes are
/// driven in later phases.
final class ResponseWireTests: XCTestCase {
    private func drive(shape: String, provider: ProviderName) async throws {
        let body = try Data(contentsOf: TestPaths.testdata("wire/response/v1/bodies/\(shape).json"))
        MockURLProtocol.reset()
        MockURLProtocol.responseBody = body
        MockURLProtocol.responseStatusCode = 200

        let client = Client(provider: provider, apiKey: "key", session: MockURLProtocol.makeSession())
        let response = try await client.text.prompt("ping")

        let projection = JSONValue.object([
            ("content", .string(response.text)),
            ("error", .null),
            ("finishReason", .string(response.finishReason)),
            ("usage", .object([
                ("cacheRead", .int(Int64(response.usage.cacheRead))),
                ("cacheWrite", .int(Int64(response.usage.cacheWrite))),
                ("cost", .double(response.usage.cost)),
                ("input", .int(Int64(response.usage.input))),
                ("output", .int(Int64(response.usage.output))),
                ("reasoning", .int(Int64(response.usage.reasoning))),
            ])),
        ])

        try TestPaths.writeResponseArtifact(shape: shape, projection: projection)
        let goldenText = try String(
            contentsOf: TestPaths.testdata("wire/response/v1/\(shape).json"), encoding: .utf8
        )
        XCTAssertEqual(projection, try JSONValue.parse(goldenText), "\(shape) projection differs from shared golden")
    }

    func testChatOpenAI() async throws { try await drive(shape: "chat-openai", provider: .openai) }
    func testChatAnthropic() async throws { try await drive(shape: "chat-anthropic", provider: .anthropic) }
    func testChatGoogle() async throws { try await drive(shape: "chat-google", provider: .google) }

    /// Streaming variant: feed an anchored SSE frame stream (`bodies/<shape>.sse`)
    /// through the real `Text.stream` path and assert the assembled Response
    /// normalizes to the same projection (ADR-065 B-stream).
    private func driveStream(shape: String, provider: ProviderName) async throws {
        let body = try Data(contentsOf: TestPaths.testdata("wire/response/v1/bodies/\(shape).sse"))
        MockURLProtocol.reset()
        MockURLProtocol.responseBody = body
        MockURLProtocol.responseStatusCode = 200

        let client = Client(provider: provider, apiKey: "key", session: MockURLProtocol.makeSession())
        let response = try await client.text.stream("ping") { _ in }

        let projection = JSONValue.object([
            ("content", .string(response.text)),
            ("error", .null),
            ("finishReason", .string(response.finishReason)),
            ("usage", .object([
                ("cacheRead", .int(Int64(response.usage.cacheRead))),
                ("cacheWrite", .int(Int64(response.usage.cacheWrite))),
                ("cost", .double(response.usage.cost)),
                ("input", .int(Int64(response.usage.input))),
                ("output", .int(Int64(response.usage.output))),
                ("reasoning", .int(Int64(response.usage.reasoning))),
            ])),
        ])

        try TestPaths.writeResponseArtifact(shape: shape, projection: projection)
        let goldenText = try String(
            contentsOf: TestPaths.testdata("wire/response/v1/\(shape).json"), encoding: .utf8
        )
        XCTAssertEqual(projection, try JSONValue.parse(goldenText), "\(shape) projection differs from shared golden")
    }

    func testStreamOpenAI() async throws { try await driveStream(shape: "stream-openai", provider: .openai) }
    func testStreamGoogle() async throws { try await driveStream(shape: "stream-google", provider: .google) }

    /// Image variant: feed an anchored image-generation reply through the real
    /// `Image.generate` path and assert the decoded `ImageResponse` projects to
    /// the media discriminant `{kind, mimeType, byteLen, count}` (RWR-004) — the
    /// same body must decode to the same images across all four SDKs (BUG-024).
    private func driveImage(shape: String, provider: ProviderName, model: String) async throws {
        let body = try Data(contentsOf: TestPaths.testdata("wire/response/v1/bodies/\(shape).json"))
        MockURLProtocol.reset()
        MockURLProtocol.responseBody = body
        MockURLProtocol.responseStatusCode = 200

        let client = Client(provider: provider, apiKey: "key", session: MockURLProtocol.makeSession())
            .baseURL("https://mock.local")
        let response = try await client.image.model(model).generate("a cat")

        let first = response.images.first
        let projection = JSONValue.object([
            ("content", .object([
                ("byteLen", .int(Int64(first?.bytes.count ?? 0))),
                ("count", .int(Int64(response.images.count))),
                ("kind", .string("image")),
                ("mimeType", .string(first?.mimeType ?? "")),
            ])),
            ("error", .null),
            ("finishReason", .string(response.finishReason)),
            ("usage", .object([
                ("cacheRead", .int(Int64(response.usage.cacheRead))),
                ("cacheWrite", .int(Int64(response.usage.cacheWrite))),
                ("cost", .double(response.usage.cost)),
                ("input", .int(Int64(response.usage.input))),
                ("output", .int(Int64(response.usage.output))),
                ("reasoning", .int(Int64(response.usage.reasoning))),
            ])),
        ])

        try TestPaths.writeResponseArtifact(shape: shape, projection: projection)
        let goldenText = try String(
            contentsOf: TestPaths.testdata("wire/response/v1/\(shape).json"), encoding: .utf8
        )
        XCTAssertEqual(projection, try JSONValue.parse(goldenText), "\(shape) projection differs from shared golden")
    }

    func testImageGoogle() async throws {
        try await driveImage(shape: "image-google", provider: .google, model: "gemini-3.1-flash-image-preview")
    }

    func testImageOpenAI() async throws {
        try await driveImage(shape: "image-openai", provider: .openai, model: "gpt-image-1")
    }

    func testImageVertex() async throws {
        try await driveImage(shape: "image-vertex", provider: .vertex, model: "imagen-3.0-generate-002")
    }
}
