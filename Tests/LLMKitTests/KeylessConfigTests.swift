import XCTest
@testable import LLMKit

///
///
///
///
///
///
///
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

    ///
    func testUnconfiguredProviderReturnsNil() {
        XCTAssertNil(imageGenConfig(.anthropic))
        XCTAssertNil(speechGenConfig(.google))
    }
}
