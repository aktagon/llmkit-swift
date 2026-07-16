import Foundation
import XCTest

@testable import LLMKit

/// HTTP runtime tests for the catalogue (ADR-019 Phase 3). Mirror of Rust
/// rust/tests/catalogue_http.rs, go/models_test.go, ts/tests/catalogue_http.test.ts
/// and python/tests/test_catalogue_http.py. Drives the live list/get/live paths
/// through the injected MockURLProtocol transport.
final class CatalogueHTTPTests: XCTestCase {
    private let base = "https://mock.test"

    private func client(_ provider: ProviderName) -> Client {
        Client(provider: provider, apiKey: "test-key", session: MockURLProtocol.makeSession())
            .baseURL(base)
    }

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    func testScopedListAnthropicCursorPagination() async throws {
        let page1 = #"{"data":[{"type":"model","id":"claude-opus-4-7","display_name":"Claude Opus 4.7","created_at":"2026-04-14T00:00:00Z","max_input_tokens":1000000,"max_tokens":128000},{"type":"model","id":"claude-sonnet-4-6","display_name":"Claude Sonnet 4.6","created_at":"2026-04-14T00:00:00Z","max_input_tokens":1000000,"max_tokens":128000}],"has_more":true,"last_id":"claude-sonnet-4-6"}"#
        let page2 = #"{"data":[{"type":"model","id":"claude-haiku-4-5-20251001","display_name":"Claude Haiku 4.5","created_at":"2026-04-14T00:00:00Z","max_input_tokens":200000,"max_tokens":64000}],"has_more":false,"last_id":"claude-haiku-4-5-20251001"}"#
        MockURLProtocol.responseSequence = [Data(page1.utf8), Data(page2.utf8)]

        let models = try await client(.anthropic).models.provider(.anthropic).list()
        XCTAssertEqual(models.count, 3)
        XCTAssertEqual(MockURLProtocol.capturedURLs.count, 2)
        XCTAssertTrue(MockURLProtocol.capturedURLs[1].contains("after_id=claude-sonnet-4-6"))
        // x-api-key (HeaderAPIKey) auth on the last request.
        XCTAssertEqual(MockURLProtocol.capturedHeaders["x-api-key"], "test-key")
        let opus = try XCTUnwrap(models.first { $0.id == "claude-opus-4-7" })
        XCTAssertFalse(opus.capabilities.isEmpty, "ontology-enriched")
    }

    func testScopedListGoogleOpaqueTokenPagination() async throws {
        let page1 = #"{"models":[{"name":"models/gemini-2.5-flash","displayName":"Gemini 2.5 Flash","description":"Stable","inputTokenLimit":1048576,"outputTokenLimit":65536}],"nextPageToken":"opaque-cursor-xyz"}"#
        let page2 = #"{"models":[{"name":"models/gemini-2.5-pro","displayName":"Gemini 2.5 Pro","description":"Stable","inputTokenLimit":1048576,"outputTokenLimit":65536}]}"#
        MockURLProtocol.responseSequence = [Data(page1.utf8), Data(page2.utf8)]

        let models = try await client(.google).models.provider(.google).list()
        XCTAssertEqual(models.count, 2)
        // Parser strips the models/ prefix from response.name.
        XCTAssertEqual(models[0].id, "gemini-2.5-flash")
        XCTAssertEqual(MockURLProtocol.capturedURLs.count, 2)
        // QueryParamKey auth rides the URL, cursor on the second page.
        XCTAssertTrue(MockURLProtocol.capturedURLs[0].contains("key=test-key"))
        XCTAssertTrue(MockURLProtocol.capturedURLs[1].contains("pageToken=opaque-cursor-xyz"))
    }

    func testScopedListOpenAINonPaginated() async throws {
        let body = #"{"object":"list","data":[{"id":"gpt-5","object":"model","created":1715367049,"owned_by":"system"},{"id":"gpt-4o","object":"model","created":1715367049,"owned_by":"system"}]}"#
        MockURLProtocol.responseBody = Data(body.utf8)

        let models = try await client(.openai).models.provider(.openai).list()
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(MockURLProtocol.capturedURLs.count, 1)
        XCTAssertEqual(MockURLProtocol.capturedHeaders["authorization"], "Bearer test-key")
    }

    func testScopedList403ScopeMapsToScopeSentinel() async {
        MockURLProtocol.responseStatusCode = 403
        MockURLProtocol.responseBody = Data(#"{"error":{"message":"Missing scopes: api.model.read"}}"#.utf8)
        do {
            _ = try await client(.openai).models.provider(.openai).list()
            XCTFail("expected scope error")
        } catch let err as CatalogueError {
            guard case .scope = err else { return XCTFail("expected .scope, got \(err)") }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testScopedList503MapsToUnavailableSentinel() async {
        MockURLProtocol.responseStatusCode = 503
        MockURLProtocol.responseBody = Data(#"{"error":"down"}"#.utf8)
        do {
            _ = try await client(.anthropic).models.provider(.anthropic).list()
            XCTFail("expected unavailable error")
        } catch let err as CatalogueError {
            guard case .unavailable = err else { return XCTFail("expected .unavailable, got \(err)") }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testScopedGetAnthropicSingleRecord() async throws {
        let body = #"{"type":"model","id":"claude-opus-4-7","display_name":"Claude Opus 4.7","created_at":"2026-04-14T00:00:00Z","max_input_tokens":1000000,"max_tokens":128000}"#
        MockURLProtocol.responseBody = Data(body.utf8)

        let model = try await client(.anthropic).models.provider(.anthropic).get("claude-opus-4-7")
        XCTAssertEqual(model.id, "claude-opus-4-7")
        XCTAssertFalse(model.capabilities.isEmpty)
        XCTAssertTrue(MockURLProtocol.capturedURLs[0].hasSuffix("/v1/models/claude-opus-4-7"))
    }

    func testModelsLivePartialSuccessTypedProviderError() async {
        MockURLProtocol.responseStatusCode = 503
        MockURLProtocol.responseBody = Data("{}".utf8)

        let result = await client(.openai).models.live()
        XCTAssertTrue(result.models.isEmpty)
        let err = result.errors["openai"]
        XCTAssertEqual(err?.kind, "unavailable")
    }
}
