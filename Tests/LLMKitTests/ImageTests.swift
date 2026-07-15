import XCTest
@testable import LLMKit

/// Mock-server unit tests for the image-generation capability (`Image.swift`).
/// Each response-parse test drives the real `client.image.generate(...)` path
/// against a canned provider reply and asserts `actual == expected` on the
/// decoded `ImageResponse`, exercising all three response shapes
/// (`GoogleParts` / `DataArrayB64Json` / `VertexPredictions`) selected by the
/// generated `imageGenConfig(provider).responseShape` — never provider name
/// (BUG-024). The request-body and validation cells complete the port coverage.
final class ImageTests: XCTestCase {
    /// A valid 1x1 PNG shared with the wire drivers.
    private static let pngBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGM4YWQEAALyAS2saifrAAAAAElFTkSuQmCC"
    private func pngBytes() throws -> [UInt8] {
        [UInt8](try XCTUnwrap(Data(base64Encoded: Self.pngBase64)))
    }

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

    // MARK: - Response parsing (GoogleParts shape)

    func testGooglePartsResponseDecodes() async throws {
        let response = """
        {"candidates":[{"content":{"parts":[{"inlineData":{"mimeType":"image/png","data":"\(Self.pngBase64)"}}]}}],\
        "usageMetadata":{"promptTokenCount":9,"candidatesTokenCount":1290}}
        """
        let resp = try await client(.google, response: response).image
            .model("gemini-3.1-flash-image-preview")
            .generate("A lighthouse on a rocky coastline at dusk")

        XCTAssertEqual(resp.images.count, 1)
        XCTAssertEqual(resp.images[0].mimeType, "image/png")
        XCTAssertEqual(resp.images[0].bytes, try pngBytes())
        XCTAssertEqual(resp.usage.input, 9)
        XCTAssertEqual(resp.usage.output, 1290)
        XCTAssertEqual(resp.text, "")
    }

    func testGooglePartsCapturesTextAndFinishReason() async throws {
        let response = """
        {"candidates":[{"finishReason":"STOP","content":{"parts":[\
        {"text":"Here is your lighthouse:"},\
        {"inlineData":{"mimeType":"image/png","data":"\(Self.pngBase64)"}}]}}],\
        "usageMetadata":{"promptTokenCount":5,"candidatesTokenCount":100}}
        """
        let resp = try await client(.google, response: response).image
            .model("gemini-3-pro-image-preview").aspectRatio("4:3").includeText()
            .generate("A watercolor map of the Baltic Sea")

        XCTAssertEqual(resp.text, "Here is your lighthouse:")
        XCTAssertEqual(resp.finishReason, "STOP")
        XCTAssertEqual(resp.images.count, 1)
        // includeText widened the response modalities on the wire.
        XCTAssertEqual(
            capturedField("generationConfig.responseModalities"),
            .array([.string("TEXT"), .string("IMAGE")])
        )
    }

    // MARK: - Response parsing (DataArrayB64Json shape)

    func testDataArrayResponseDecodes() async throws {
        let response = """
        {"data":[{"b64_json":"\(Self.pngBase64)"}],"usage":{"input_tokens":12,"output_tokens":260}}
        """
        let resp = try await client(.openai, response: response).image
            .model("gpt-image-2").imageSize("1024x1024").quality("low")
            .generate("A minimalist line drawing of a sailboat")

        XCTAssertEqual(resp.images.count, 1)
        XCTAssertEqual(resp.images[0].mimeType, "image/png")
        XCTAssertEqual(resp.images[0].bytes, try pngBytes())
        XCTAssertEqual(resp.usage.input, 12)
        XCTAssertEqual(resp.usage.output, 260)
    }

    /// Recraft vector models return SVG bytes in the same `b64_json` slot with no
    /// echoed mime type; the parser sniffs the leading bytes to `image/svg+xml`.
    func testDataArraySniffsSVG() async throws {
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\"><rect width=\"10\" height=\"10\"/></svg>"
        let svgBase64 = Data(svg.utf8).base64EncodedString()
        let response = "{\"data\":[{\"b64_json\":\"\(svgBase64)\"}]}"
        let resp = try await client(.recraft, response: response).image
            .model("recraftv3_vector")
            .generate("A minimalist line drawing of a sailboat")

        XCTAssertEqual(resp.images.count, 1)
        XCTAssertEqual(resp.images[0].mimeType, "image/svg+xml")
        XCTAssertEqual(resp.images[0].bytes, [UInt8](Data(svg.utf8)))
        // Recraft reports no token counts, so usage stays zero.
        XCTAssertEqual(resp.usage.input, 0)
        XCTAssertEqual(resp.usage.output, 0)
    }

    // MARK: - Response parsing (VertexPredictions shape)

    func testVertexPredictionsResponseDecodes() async throws {
        let response = """
        {"predictions":[{"bytesBase64Encoded":"\(Self.pngBase64)","mimeType":"image/png"}]}
        """
        let resp = try await client(.vertex, response: response).image
            .model("imagen-3.0-generate-002")
            .generate("A lighthouse on a rocky coastline at dusk")

        XCTAssertEqual(resp.images.count, 1)
        XCTAssertEqual(resp.images[0].mimeType, "image/png")
        XCTAssertEqual(resp.images[0].bytes, try pngBytes())
        // Vertex reports no token counts.
        XCTAssertEqual(resp.usage.input, 0)
        XCTAssertEqual(resp.usage.output, 0)
    }

    // MARK: - Request body (Vertex instances/parameters envelope)

    func testVertexBodyWrapsInstancesAndParameters() async throws {
        let response = "{\"predictions\":[{\"bytesBase64Encoded\":\"\(Self.pngBase64)\"}]}"
        _ = try await client(.vertex, response: response).image
            .model("imagen-3.0-generate-002").aspectRatio("16:9")
            .generate("A lighthouse on a rocky coastline at dusk")

        let body = try capturedBody()
        XCTAssertEqual(body.lookup("instances[0].prompt"), .string("A lighthouse on a rocky coastline at dusk"))
        XCTAssertEqual(body.lookup("parameters.sampleCount"), .int(1))
        XCTAssertEqual(body.lookup("parameters.aspectRatio"), .string("16:9"))
    }

    // MARK: - Validation

    func testRequiresModel() async throws {
        do {
            _ = try await client(.google, response: "{}").image.generate("A lighthouse")
            XCTFail("expected a validation error")
        } catch let LLMKitError.validation(field, _) {
            XCTAssertEqual(field, "model")
        }
    }

    func testRejectsBothEmpty() async throws {
        do {
            _ = try await client(.google, response: "{}").image
                .model("gemini-3.1-flash-image-preview").generate("")
            XCTFail("expected a validation error")
        } catch let LLMKitError.validation(field, _) {
            XCTAssertEqual(field, "prompt")
        }
    }

    func testRejectsUnsupportedAspectRatioOnPro() async throws {
        do {
            // 1:4 is a Flash-only ratio; the Pro model whitelist excludes it.
            _ = try await client(.google, response: "{}").image
                .model("gemini-3-pro-image-preview").aspectRatio("1:4").generate("A map")
            XCTFail("expected a validation error")
        } catch let LLMKitError.validation(field, _) {
            XCTAssertEqual(field, "aspect_ratio")
        }
    }

    func testRejectsQualityOnGoogle() async throws {
        do {
            _ = try await client(.google, response: "{}").image
                .model("gemini-3.1-flash-image-preview").quality("high").generate("A map")
            XCTFail("expected a validation error")
        } catch let LLMKitError.validation(field, _) {
            XCTAssertEqual(field, "quality")
        }
    }

    func testRejectsAspectRatioOnRecraft() async throws {
        do {
            _ = try await client(.recraft, response: "{}").image
                .model("recraftv3").aspectRatio("1:1").generate("A sailboat")
            XCTFail("expected a validation error")
        } catch let LLMKitError.validation(field, _) {
            XCTAssertEqual(field, "aspect_ratio")
        }
    }

    // MARK: - Helpers

    private func capturedField(_ path: String) -> JSONValue? {
        guard let data = MockURLProtocol.capturedBody,
              let body = try? JSONValue.parse(String(decoding: data, as: UTF8.self)) else { return nil }
        return body.lookup(path)
    }
}
