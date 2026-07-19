import XCTest
@testable import LLMKit

///
///
///
///
///
///
///
final class ImageTests: XCTestCase {
    ///
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

    //

    func testGooglePartsResponseDecodes() async throws {
        let response = """
        {"candidates":[{"content":{"parts":[{"inlineData":{"mimeType":"image/png","data":"\(Self.pngBase64)"}}]}}],\
        "usageMetadata":{"promptTokenCount":9,"candidatesTokenCount":1290}}
        """













"""
        {"candidates":[{"finishReason":"STOP","content":{"parts":[\
        {"text":"Here is your lighthouse:"},\
        {"inlineData":{"mimeType":"image/png","data":"\(Self.pngBase64)"}}]}}],\
        "usageMetadata":{"promptTokenCount":5,"candidatesTokenCount":100}}
        """

















"""
        {"data":[{"b64_json":"\(Self.pngBase64)"}],"usage":{"input_tokens":12,"output_tokens":260}}
        """
































"""
        {"predictions":[{"bytesBase64Encoded":"\(Self.pngBase64)","mimeType":"image/png"}]}
        """
        let resp = try await client(.vertex, response: response).image
            .model("imagen-3.0-generate-002")
            .generate("A lighthouse on a rocky coastline at dusk")

        XCTAssertEqual(resp.images.count, 1)
        XCTAssertEqual(resp.images[0].mimeType, "image/png")
        XCTAssertEqual(resp.images[0].bytes, try pngBytes())
        //
        XCTAssertEqual(resp.usage.input, 0)
        XCTAssertEqual(resp.usage.output, 0)
    }

    //

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

    //

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
            //
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

    //

    private func capturedField(_ path: String) -> JSONValue? {
        guard let data = MockURLProtocol.capturedBody,
              let body = try? JSONValue.parse(String(decoding: data, as: UTF8.self)) else { return nil }
        return body.lookup(path)
    }
}
