import XCTest
@testable import LLMKit

/// Phase 4h Part 1: the four media `*GenConfig` accessors are the ADR-036
/// public-surface symbols a consumer calls at module-load — no client, no API
/// key, no network — to derive a model menu (imageGenConfig / videoGenConfig /
/// musicGenConfig / speechGenConfig, plus their config structs). These assert
/// they are publicly reachable and return real catalogue data. The runtime
/// capability tests already cover the values in depth; this pins the public
/// keyless surface itself so a regression to `internal` fails loudly.
final class KeylessConfigTests: XCTestCase {
    func testImageGenConfigKeyless() {
        let cfg = imageGenConfig(.google)
        XCTAssertNotNil(cfg)
        XCTAssertEqual(cfg?.inputMode, "InlineParts")
        XCTAssertEqual(cfg?.outputMode, "Base64Inline")
        XCTAssertTrue(cfg?.models.contains { $0.modelId == "gemini-3-pro-image-preview" } ?? false)
    }

    func testVideoGenConfigKeyless() {
        let cfg = videoGenConfig(.bedrock)
        XCTAssertNotNil(cfg)
        XCTAssertTrue(cfg?.models.contains { $0.modelId == "amazon.nova-reel-v1:0" } ?? false)
    }

    func testMusicGenConfigKeyless() {
        let cfg = musicGenConfig(.google)
        XCTAssertNotNil(cfg)
        XCTAssertTrue(cfg?.models.contains { $0.modelId == "lyria-3-clip-preview" } ?? false)
    }

    func testSpeechGenConfigKeyless() {
        let cfg = speechGenConfig(.openai)
        XCTAssertNotNil(cfg)
        XCTAssertEqual(cfg?.wireShape, "SpeechOpenAI")
        XCTAssertEqual(cfg?.audioResponseEncoding, "rawBody")
        XCTAssertEqual(cfg?.genEndpoint, "/v1/audio/speech")
    }

    /// A provider with no config for a capability returns nil (not a crash).
    func testUnconfiguredProviderReturnsNil() {
        XCTAssertNil(imageGenConfig(.anthropic))
        XCTAssertNil(speechGenConfig(.google))
    }
}
