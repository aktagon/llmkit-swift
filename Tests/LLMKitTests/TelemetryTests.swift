import XCTest
@testable import LLMKit

/// Behavior tests for the client-scoped telemetry seam (Phase 4g): addTelemetry
/// installs a post-phase export hook on every capability builder, so a prompt
/// emits one OTLP span carrying the call's operation/provider/model/usage. The
/// wire goldens assert the pure builder; these assert the middleware wiring +
/// the fail-open + error classification the goldens never exercise.
final class TelemetryTests: XCTestCase {
    /// Synchronous recorder for the OTLP payloads the export hook emits.
    private final class Recorder: @unchecked Sendable {
        var payloads: [String] = []
        func record(_ data: Data) { payloads.append(String(decoding: data, as: UTF8.self)) }
    }

    private static let chatResponse =
        "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"Helsinki\"}}]," +
        "\"usage\":{\"prompt_tokens\":11,\"completion_tokens\":3}}"

    func testAddTelemetryEmitsSpanOnPrompt() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.responseBody = Data(Self.chatResponse.utf8)
        MockURLProtocol.responseStatusCode = 200

        let recorder = Recorder()
        let telemetry = Telemetry(export: { recorder.record($0) })
        let client = Client(provider: .openai, apiKey: "key", session: MockURLProtocol.makeSession())
            .addTelemetry(telemetry)

        let response = try await client.text.model("gpt-4o").prompt("Capital of Finland?")
        XCTAssertEqual(response.text, "Helsinki")

        // Exactly one span was exported (post phase only; pre is a no-op).
        XCTAssertEqual(recorder.payloads.count, 1)
        let span = try JSONValue.parse(try XCTUnwrap(recorder.payloads.first))
        let attrs = try XCTUnwrap(spanAttributes(span))
        XCTAssertEqual(attrs["gen_ai.operation.name"], "chat")
        XCTAssertEqual(attrs["gen_ai.system"], "openai")
        XCTAssertEqual(attrs["gen_ai.request.model"], "gpt-4o")
        XCTAssertEqual(attrs["gen_ai.usage.input_tokens"], "11")
        XCTAssertEqual(attrs["gen_ai.usage.output_tokens"], "3")
    }

    func testTelemetryIsFailOpen() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.responseBody = Data(Self.chatResponse.utf8)
        MockURLProtocol.responseStatusCode = 200

        // An export hook that throws-equivalent (does nothing observable but could
        // fault) must never surface to the caller — the prompt still returns.
        struct Boom: Error {}
        let client = Client(provider: .openai, apiKey: "key", session: MockURLProtocol.makeSession())
            .addTelemetry(Telemetry(export: { _ in _ = Boom() }))
        let response = try await client.text.model("gpt-4o").prompt("Capital of Finland?")
        XCTAssertEqual(response.text, "Helsinki")
    }

    /// The batteries exporter POSTs through the injected session (HANDOFF-036
    /// B4) — previously the one HTTP call in the SDK a test transport could not
    /// intercept. Asserts URL assembly (`/v1/traces` suffix), the caller's
    /// headers, and the payload arriving verbatim. Fire-and-forget, so the
    /// capture is polled rather than awaited.
    func testHTTPExportPostsThroughInjectedSession() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.responseStatusCode = 200

        let export = Telemetry.httpExport(
            endpoint: "https://collector.example.com",
            headers: ["Authorization": "Bearer otlp-token"],
            session: MockURLProtocol.makeSession()
        )
        let payload = "{\"resourceSpans\":[]}"
        export(Data(payload.utf8))

        for _ in 0..<200 where MockURLProtocol.capturedBody == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(MockURLProtocol.capturedURLs.first, "https://collector.example.com/v1/traces")
        XCTAssertEqual(MockURLProtocol.capturedHeaders["authorization"], "Bearer otlp-token")
        XCTAssertEqual(MockURLProtocol.capturedHeaders["content-type"], "application/json")
        XCTAssertEqual(
            MockURLProtocol.capturedBody.map { String(decoding: $0, as: UTF8.self) },
            payload
        )
    }

    /// Round-trip: classification is asserted on the exact strings the runtime
    /// renders via `Middleware.errString` for REAL thrown errors — never on
    /// hand-written strings the runtime does not produce.
    func testErrStringClassificationRoundTrip() {
        let validation = LLMKitError.validation(field: "model", message: "no model configured for openai")
        XCTAssertEqual(Middleware.errString(validation), "validation: model - no model configured for openai")
        XCTAssertEqual(TelemetryRuntime.classifyError(Middleware.errString(validation)), "validation_error")

        let unsupported = LLMKitError.unsupported("batch create: empty batch ID")
        XCTAssertEqual(Middleware.errString(unsupported), "unsupported: batch create: empty batch ID")
        XCTAssertEqual(TelemetryRuntime.classifyError(Middleware.errString(unsupported)), "error")

        let transport = LLMKitError.transport("connection reset by peer")
        XCTAssertEqual(TelemetryRuntime.classifyError(Middleware.errString(transport)), "error")

        let decoding = LLMKitError.decoding("response carried no choices")
        XCTAssertEqual(TelemetryRuntime.classifyError(Middleware.errString(decoding)), "error")

        struct RateLimitPolicy: Error {}
        let veto = MiddlewareVeto(cause: RateLimitPolicy())
        XCTAssertTrue(Middleware.errString(veto).hasPrefix("middleware veto: "))
        XCTAssertEqual(TelemetryRuntime.classifyError(Middleware.errString(veto)), "error")

        let api = LLMKitError.api(provider: "openai", statusCode: 429, message: "rate limited")
        XCTAssertEqual(Middleware.errString(api), "openai: rate limited (429)")
        XCTAssertEqual(TelemetryRuntime.classifyError(Middleware.errString(api)), "api_error")

        XCTAssertEqual(TelemetryRuntime.classifyError(""), "")
    }

    /// End-to-end: a real validation rejection inside the llmRequest fire scope
    /// (caching on a provider without a caching config) must export a span whose
    /// error.type is "validation_error" — not the api_error fallback the old
    /// reflection-rendered Event.err always produced.
    func testRejectionSpanCarriesValidationErrorType() async throws {
        MockURLProtocol.reset()
        let recorder = Recorder()
        let client = Client(provider: .grok, apiKey: "key", session: MockURLProtocol.makeSession())
            .addTelemetry(Telemetry(export: { recorder.record($0) }))
        do {
            _ = try await client.text.model("grok-4").caching().prompt("Capital of Finland?")
            XCTFail("caching on grok must reject pre-flight")
        } catch LLMKitError.validation(let field, _) {
            XCTAssertEqual(field, "caching")
        }
        XCTAssertEqual(recorder.payloads.count, 1)
        let span = try JSONValue.parse(try XCTUnwrap(recorder.payloads.first))
        let attrs = try XCTUnwrap(spanAttributes(span))
        XCTAssertEqual(attrs["error.type"], "validation_error")
    }

    /// The catalogue path fires the client-scoped default middleware (one
    /// modelsList pre+post pair per list() call), so telemetry observes live
    /// catalogue calls too.
    func testModelsListFiresClientMiddleware() async throws {
        MockURLProtocol.reset()
        let body = #"{"object":"list","data":[{"id":"gpt-5","object":"model","created":1715367049,"owned_by":"system"}]}"#
        MockURLProtocol.responseBody = Data(body.utf8)

        final class PhaseRecorder: @unchecked Sendable {
            var fires: [(MiddlewareOp, MiddlewarePhase)] = []
        }
        let phases = PhaseRecorder()
        let client = Client(provider: .openai, apiKey: "key", session: MockURLProtocol.makeSession())
            .baseURL("https://mock.test")
            .addMiddleware { event in
                phases.fires.append((event.op, event.phase))
                return nil
            }

        let models = try await client.models.provider(.openai).list()
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(phases.fires.count, 2, "exactly one pre+post pair per list() call")
        XCTAssertEqual(phases.fires[0].0, .modelsList)
        XCTAssertEqual(phases.fires[0].1, .pre)
        XCTAssertEqual(phases.fires[1].0, .modelsList)
        XCTAssertEqual(phases.fires[1].1, .post)
    }

    /// Extract the single span's attributes as a flat [key: stringValueOrIntValue].
    private func spanAttributes(_ payload: JSONValue) -> [String: String]? {
        guard let span = payload
            .lookup("resourceSpans[0].scopeSpans[0].spans[0]"),
            case let .array(attrs)? = span.member("attributes") else { return nil }
        var out: [String: String] = [:]
        for attr in attrs {
            let key = attr.stringValue(at: "key")
            let value = attr.member("value")
            if case let .string(s)? = value?.member("stringValue") { out[key] = s }
            else if case let .string(s)? = value?.member("intValue") { out[key] = s }
        }
        return out
    }
}
