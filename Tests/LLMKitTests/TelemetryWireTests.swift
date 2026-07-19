import XCTest
@testable import LLMKit

///
///
///
///
///
///
final class TelemetryWireTests: XCTestCase {
    private func assertGolden(_ fixture: String, _ payload: String) throws {
        try TestPaths.writeTelemetryArtifact(fixture: fixture, payload: payload)
        let goldenText = try String(
            contentsOf: TestPaths.testdata("wire/telemetry/v1/\(fixture).json"), encoding: .utf8
        )
        XCTAssertEqual(
            try JSONValue.parse(payload), try JSONValue.parse(goldenText),
            "\(fixture) OTLP payload differs from shared golden"
        )
    }

    func testTelemetrySuccess() throws {
        let payload = TelemetryRuntime.buildOTLPTraces(
            operationName: "chat", provider: "openai", model: "gpt-4o",
            inputTokens: 10, outputTokens: 20, errorType: "",
            traceId: "5b8efff798038103d269b633813fc60c", spanId: "eee19b7ec3c1b174",
            startNano: "1700000000000000000", endNano: "1700000001000000000"
        )
        try assertGolden("telemetry-success", payload)
    }

    func testTelemetryRejection() throws {
        let payload = TelemetryRuntime.buildOTLPTraces(
            operationName: "chat", provider: "openai", model: "gpt-4o",
            inputTokens: 0, outputTokens: 0, errorType: "rate_limit_exceeded",
            traceId: "5b8efff798038103d269b633813fc60c", spanId: "eee19b7ec3c1b174",
            startNano: "1700000000000000000", endNano: "1700000001000000000"
        )
        try assertGolden("telemetry-rejection", payload)
    }

    ///
    ///
    ///
    ///
    func testTelemetryError() throws {
        var event = Event(op: .llmRequest, provider: "openai", model: "gpt-4o", phase: .post)
        Middleware.setError(
            &event, LLMKitError.api(provider: "openai", statusCode: 429, message: "rate limited")
        )
        XCTAssertEqual(event.errType, "api_error", "setError must stamp errType from the typed error")
        let payload = TelemetryRuntime.buildPayloadAt(
            event,
            traceId: "5b8efff798038103d269b633813fc60c", spanId: "eee19b7ec3c1b174",
            startNano: "1700000000000000000", endNano: "1700000001000000000"
        )
        try assertGolden("telemetry-error", payload)
    }
}
