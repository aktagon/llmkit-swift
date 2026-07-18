import XCTest
@testable import LLMKit

/// SigV4 canonical-request wire driver (CR-002): sign the two production-shaped
/// Bedrock requests with an injected clock and assert the canonical request,
/// string-to-sign, and Authorization header byte-identically against the shared
/// golden at codegen/testdata/wire/sigv4/v1/<fixture>.json. The same fixed
/// inputs are hard-coded in every SDK's driver; each test also drops
/// target/wire/sigv4/<fixture>/swift.json for the cross-SDK comparator.
final class SigV4WireTests: XCTestCase {
    /// The frozen signing clock shared by every SDK driver: 2026-07-18T00:00:00Z.
    private static let now: Date = {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(identifier: "UTC")!
        components.year = 2026
        components.month = 7
        components.day = 18
        return components.date!
    }()

    private static let accessKey = "AKIDEXAMPLE"
    private static let secretKey = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"  // AWS docs example creds #gitleaks:allow
    private static let sessionToken = "IQoJb3JpZ2luX2VjEXAMPLETOKEN"  // AWS docs example creds #gitleaks:allow

    private func assertGolden(_ fixture: String, _ parts: SigV4.Parts) throws {
        let artifact = JSONValue.object([
            ("canonicalRequest", .string(parts.canonicalRequest)),
            ("stringToSign", .string(parts.stringToSign)),
            ("authorization", .string(parts.authorization)),
        ])
        try TestPaths.writeSigV4Artifact(fixture: fixture, projection: artifact)
        let goldenText = try String(
            contentsOf: TestPaths.testdata("wire/sigv4/v1/\(fixture).json"), encoding: .utf8
        )
        let golden = try JSONValue.parse(goldenText)
        for key in ["canonicalRequest", "stringToSign", "authorization"] {
            XCTAssertEqual(
                artifact.member(key), golden.member(key),
                "\(fixture) \(key) differs from shared golden"
            )
        }
    }

    /// Mirrors postJSONSigV4's request assembly for the Bedrock Converse chat
    /// path: POST, Content-Type sent and therefore signed, session token
    /// present, model id ':' literal in the path.
    func testSigV4WireChatPost() throws {
        let body = Data(#"{"messages":[{"role":"user","content":[{"text":"Hello, Bedrock"}]}]}"#.utf8)
        let url = URL(string:
            "https://bedrock-runtime.us-east-1.amazonaws.com/model/anthropic.claude-3-haiku-20240307-v1:0/converse"
        )!
        let parts = SigV4.signParts(
            method: "POST", url: url, body: body,
            accessKey: Self.accessKey, secretKey: Self.secretKey, sessionToken: Self.sessionToken,
            region: "us-east-1", service: "bedrock", contentType: "application/json", now: Self.now
        )
        try assertGolden("sigv4-chat-post", parts)
    }

    /// Mirrors getTextSigV4's request assembly for the Bedrock async-invoke
    /// poll: GET, empty body (empty-string SHA-256 payload hash), NO
    /// Content-Type signed, no session token, and the invocation ARN
    /// percent-encoded as ONE path segment ('/' -> %2F, ':' literal) so the
    /// signed path equals the wire path.
    func testSigV4WirePollGet() throws {
        let url = URL(string:
            "https://bedrock-runtime.us-west-2.amazonaws.com/async-invoke/arn:aws:bedrock:us-west-2:123456789012:async-invoke%2Fabc123xyz"
        )!
        let parts = SigV4.signParts(
            method: "GET", url: url, body: Data(),
            accessKey: Self.accessKey, secretKey: Self.secretKey, sessionToken: "",
            region: "us-west-2", service: "bedrock", contentType: "", now: Self.now
        )
        try assertGolden("sigv4-poll-get", parts)
    }
}
