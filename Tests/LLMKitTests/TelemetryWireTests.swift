import XCTest
@testable import LLMKit

/// Telemetry-wire driver (ADR-054 TEL-011): call the PURE OTLP builder with the
/// SAME fixed inputs the other four SDKs feed and assert the payload is
/// value-equal to the shared golden at codegen/testdata/wire/telemetry/v1/. Each
/// test also drops target/wire/telemetry/<fixture>/swift.json so the cross-SDK
/// comparator (codegen/test_cross_sdk_telemetry_wire.py) can enroll Swift. Span
/// identity + timing are injected fixed so the payload is byte-stable.
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

    /// Exercises classification end-to-end (ADR-071 ETY-004): the SDK's typed
    /// API error routes through the REAL erasure seam (`Middleware.setError`),
    /// and the stamped event renders to the shared telemetry-error golden via
    /// the pure event-level builder — no error.type is hand-fed anywhere.
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
