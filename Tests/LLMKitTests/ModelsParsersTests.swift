import Foundation
import XCTest

@testable import LLMKit

/// Parser tests against codegen/fixtures/models/* (ADR-019). Mirror of Rust
/// rust/tests/models_parsers.rs, Go go/providers/models_parsers_test.go, TS
/// ts/tests/models_parsers.test.ts, and Python python/tests/test_models_parsers.py.
final class ModelsParsersTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = TestPaths.repoRoot()
            .appendingPathComponent("codegen/fixtures/models")
            .appendingPathComponent(name)
        return try Data(contentsOf: url)
    }

    func testParseAnthropicFixtureRecordsAndMetadata() throws {
        let page = try parseAnthropicModelsResponse(fixture("anthropic.json"))
        XCTAssertEqual(page.records.count, 9)
        let first = page.records[0]
        XCTAssertFalse(first.id.isEmpty)
        XCTAssertFalse(first.displayName.isEmpty)
        XCTAssertGreaterThan(first.contextWindow, 0)
        XCTAssertGreaterThan(first.maxOutput, 0)
    }

    func testParseAnthropicRoundTripsRaw() throws {
        let page = try parseAnthropicModelsResponse(fixture("anthropic.json"))
        XCTAssertNotNil(page.records[0].raw)
    }

    func testParseOpenAICohortFixtureRecordsAndNoPagination() throws {
        let page = try parseOpenAICohortModelsResponse(fixture("openai.json"))
        XCTAssertEqual(page.records.count, 124)
        XCTAssertEqual(page.nextCursor, "")
        XCTAssertFalse(page.records[0].id.isEmpty)
        XCTAssertGreaterThan(page.records[0].created, 0)
    }

    func testParseAnthropicMalformedCreatedAtYieldsZero() throws {
        // Documents the silent-failure contract: a bad timestamp does not crash
        // the parser; the record just lands with created == 0.
        let body = Data(#"{"data":[{"id":"m","created_at":"not-a-date"}]}"#.utf8)
        let page = try parseAnthropicModelsResponse(body)
        XCTAssertEqual(page.records.count, 1)
        XCTAssertEqual(page.records[0].created, 0)
    }

    func testParseGoogleFixtureStripsModelsPrefix() throws {
        let page = try parseGoogleModelsResponse(fixture("google.json"))
        XCTAssertEqual(page.records.count, 50)
        for record in page.records {
            XCTAssertFalse(record.id.isEmpty)
            XCTAssertFalse(record.id.hasPrefix("models/"))
        }
        XCTAssertTrue(page.records.contains { $0.contextWindow > 0 })
    }
}
