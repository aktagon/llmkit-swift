import XCTest
@testable import LLMKit

///
///
///
///
final class SupportsTests: XCTestCase {
    private func client(_ provider: ProviderName) -> Client {
        Client(provider: provider, apiKey: "k")
    }

    func testGatedCapabilities() {
        XCTAssertTrue(client(.anthropic).supports(.caching), "anthropic gates caching → true")
        XCTAssertFalse(client(.ollama).supports(.caching), "ollama has no caching config → false")
    }

    func testUngatedCapabilitiesAlwaysTrue() {
        let c = client(.ollama)
        for cap in [Capability.chatCompletion, .toolCalling, .reasoning, .catalogue] {
            XCTAssertTrue(c.supports(cap), "ollama supports(\(cap)) should be true (no provider-level gate)")
        }
    }

    func testMatchesStrictGateLookups() {
        //
        //
        for provider in ProviderName.allCases {
            let c = client(provider)
            XCTAssertEqual(c.supports(.caching), cachingConfig(provider) != nil,
                           "\(provider.rawValue) supports(.caching)")
            XCTAssertEqual(c.supports(.batching), batchConfig(provider) != nil,
                           "\(provider.rawValue) supports(.batching)")
            XCTAssertEqual(c.supports(.fileUpload), fileUploadConfig(provider) != nil,
                           "\(provider.rawValue) supports(.fileUpload)")
            XCTAssertEqual(c.supports(.imageGeneration), imageGenConfig(provider) != nil,
                           "\(provider.rawValue) supports(.imageGeneration)")
        }
    }
}
