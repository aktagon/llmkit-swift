import Foundation
import XCTest

@testable import LLMKit

/// Compiled-in catalogue tests (ADR-019). Mirror of Rust rust/tests/catalogue.rs,
/// Go go/catalogue_test.go, TS ts/tests/catalogue.test.ts, and Python
/// python/tests/test_catalogue.py. Keyless — no HTTP.
final class CatalogueTests: XCTestCase {
    private func client(_ provider: ProviderName) -> Client {
        Client(provider: provider, apiKey: "test-key")
    }

    func testModelsListReturnsCompiledInCatalogue() {
        let models = client(.anthropic).models.list()
        XCTAssertFalse(models.isEmpty, "expected non-empty compiled-in catalogue")
        // Sort of the compiled-in table is by model_id; anthropic ids sort first.
        XCTAssertEqual(models[0].provider, .anthropic)
    }

    func testModelsWithCapabilityNarrowsToImageGeneration() {
        let c = client(.openai)
        let all = c.models.list()
        let imageOnly = c.models.withCapability(.imageGeneration).list()
        XCTAssertFalse(imageOnly.isEmpty)
        XCTAssertLessThan(imageOnly.count, all.count)
        for model in imageOnly {
            XCTAssertTrue(model.capabilities.contains(.imageGeneration))
        }
    }

    func testModelsWithCapabilityChainIsImmutable() {
        // Value-type clone-on-chain is the immutability mechanism: withCapability
        // returns a fresh builder, the original is unchanged.
        let c = client(.openai)
        let all = c.models
        let filtered = all.withCapability(.imageGeneration)
        XCTAssertGreaterThan(all.list().count, filtered.list().count)
    }

    func testModelsGetReturnsKnownModel() {
        let got = client(.anthropic).models.get("claude-opus-4-7")
        XCTAssertEqual(got?.id, "claude-opus-4-7")
    }

    func testModelsGetReturnsNilForUnknownID() {
        XCTAssertNil(client(.anthropic).models.get("nonexistent-model-xyz"))
    }

    func testProvidersListReturnsConfiguredProviderWithEndpoint() {
        let got = client(.anthropic).providers.list()
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got[0].id, .anthropic)
        XCTAssertEqual(got[0].slug, "anthropic")
    }

    func testProvidersListEmptyForEndpointlessProvider() {
        // cohere has no llm:hasModelsEndpoint -> not configured for live catalogue.
        XCTAssertTrue(client(.cohere).providers.list().isEmpty)
    }

    func testAllProviderInfoCarriesWireSlugs() {
        // ProviderInfo.slug is the wire slug ("anthropic"), never a Debug form.
        let slugs = allProviderInfo().map(\.slug)
        XCTAssertGreaterThanOrEqual(slugs.count, 10)
        XCTAssertTrue(slugs.contains("anthropic"))
        XCTAssertTrue(slugs.contains("openai"))
        XCTAssertTrue(slugs.contains("google"))
    }

    func testScopedRawFlipsChainFlag() {
        let scoped = client(.anthropic).models.provider(.anthropic)
        XCTAssertFalse(scoped.rawFlag)
        XCTAssertTrue(scoped.raw().rawFlag)
    }

    func testCatalogueErrorKindAndMessage() {
        XCTAssertEqual(CatalogueError.notSupported.kind, "not_supported")
        XCTAssertEqual(CatalogueError.unavailable("x").kind, "unavailable")
        XCTAssertEqual(CatalogueError.scope("x").kind, "scope")
        XCTAssertTrue(CatalogueError.notSupported.message.contains("models endpoint"))
        XCTAssertTrue(CatalogueError.unavailable("x").message.contains("unavailable"))
        XCTAssertTrue(CatalogueError.scope("x").message.contains("scope"))
    }

    func testScopedListNotSupportedForEndpointlessProvider() async {
        do {
            _ = try await client(.cohere).models.provider(.cohere).list()
            XCTFail("expected notSupported")
        } catch let err as CatalogueError {
            XCTAssertEqual(err, .notSupported)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testScopedGetNotSupportedForEndpointlessProvider() async {
        do {
            _ = try await client(.cohere).models.provider(.cohere).get("any")
            XCTFail("expected notSupported")
        } catch let err as CatalogueError {
            XCTAssertEqual(err, .notSupported)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
