import XCTest
@testable import LLMKit

/// Parser/equality edge cases for the hand-rolled JSON waist (ADR-066
/// SWIFT-002): surrogate-pair escapes, end-of-input enforcement, and
/// duplicate-key object equality.
final class JSONValueTests: XCTestCase {
    func testSurrogatePairEscapeParsesToEmojiAndRoundTrips() throws {
        let value = try JSONValue.parse("\"\\ud83d\\ude00\"")
        XCTAssertEqual(value, .string("\u{1F600}"))
        // Round-trip: the serializer emits the raw scalar; reparsing yields
        // the same value.
        XCTAssertEqual(try JSONValue.parse(value.serialized()), value)
    }

    func testLoneHighSurrogateEscapeThrowsInvalidEscape() {
        XCTAssertThrowsError(try JSONValue.parse("\"\\ud83d oops\"")) { error in
            XCTAssertEqual(error as? JSONValue.ParseError, .invalidEscape)
        }
    }

    func testLoneLowSurrogateEscapeThrowsInvalidEscape() {
        XCTAssertThrowsError(try JSONValue.parse("\"\\ude00\"")) { error in
            XCTAssertEqual(error as? JSONValue.ParseError, .invalidEscape)
        }
    }

    func testHighSurrogateFollowedByNonLowSurrogateEscapeThrows() {
        XCTAssertThrowsError(try JSONValue.parse("\"\\ud83d\\u0041\"")) { error in
            XCTAssertEqual(error as? JSONValue.ParseError, .invalidEscape)
        }
    }

    func testTrailingGarbageAfterDocumentThrows() {
        XCTAssertThrowsError(try JSONValue.parse("{\"model\":\"gpt-4o-mini\"}}}")) { error in
            XCTAssertEqual(error as? JSONValue.ParseError, .unexpected("}", at: 23))
        }
    }

    func testConcatenatedSecondDocumentThrows() {
        XCTAssertThrowsError(try JSONValue.parse("{\"input_tokens\":14} {\"output_tokens\":2}"))
    }

    func testChatResponseBodyWithEmojiEscapedContentParses() throws {
        // An OpenAI-shaped chat body whose assistant text carries an
        // ASCII-escaped non-BMP character, as providers legally emit.
        let body = """
        {"id":"chatcmpl-9x2","object":"chat.completion","model":"gpt-4o-mini",\
        "choices":[{"index":0,"message":{"role":"assistant",\
        "content":"Deployment finished \\ud83d\\ude00"},"finish_reason":"stop"}],\
        "usage":{"prompt_tokens":14,"completion_tokens":6,"total_tokens":20}}
        """
        let value = try JSONValue.parse(body)
        XCTAssertEqual(
            value.stringValue(at: "choices[0].message.content"),
            "Deployment finished \u{1F600}"
        )
        XCTAssertEqual(value.intValue(at: "usage.prompt_tokens"), 14)
    }

    func testDuplicateKeyObjectsWithDifferentValuesAreNotEqual() {
        let a = JSONValue.object([("role", .string("user")), ("role", .string("user"))])
        let b = JSONValue.object([("role", .string("user")), ("role", .string("assistant"))])
        XCTAssertNotEqual(a, b)
        // Distinct-key reordering stays equal (existing contract).
        let ordered = JSONValue.object([("model", .string("gpt-4o-mini")), ("stream", .bool(false))])
        let reordered = JSONValue.object([("stream", .bool(false)), ("model", .string("gpt-4o-mini"))])
        XCTAssertEqual(ordered, reordered)
    }
}
