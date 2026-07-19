import XCTest
@testable import LLMKit

///
///
///
final class JSONValueTests: XCTestCase {
    func testSurrogatePairEscapeParsesToEmojiAndRoundTrips() throws {
        let value = try JSONValue.parse("\"\\ud83d\\ude00\"")
        XCTAssertEqual(value, .string("\u{1F600}"))
        //
        //
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
        //
        //
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
        //
        let ordered = JSONValue.object([("model", .string("gpt-4o-mini")), ("stream", .bool(false))])
        let reordered = JSONValue.object([("stream", .bool(false)), ("model", .string("gpt-4o-mini"))])
        XCTAssertEqual(ordered, reordered)
    }

    func testDoubleValueReadsDoublepromotesIntAndDefaultsToZero() throws {
        let value = try JSONValue.parse(
            "{\"usage\":{\"cost\":0.0125,\"prompt_tokens\":14},\"model\":\"gpt-4o-mini\"}"
        )
        XCTAssertEqual(value.doubleValue(at: "usage.cost"), 0.0125)
        //
        XCTAssertEqual(value.doubleValue(at: "usage.prompt_tokens"), 14.0)
        //
        XCTAssertEqual(value.doubleValue(at: "model"), 0.0)
        XCTAssertEqual(value.doubleValue(at: "usage.completion_tokens"), 0.0)
    }
}
