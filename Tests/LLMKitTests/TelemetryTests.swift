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

    func testClassifyErrorPrefixes() {
        XCTAssertEqual(TelemetryRuntime.classifyError("validation: model - none"), "validation_error")
        XCTAssertEqual(TelemetryRuntime.classifyError("unsupported: nope"), "error")
        XCTAssertEqual(TelemetryRuntime.classifyError("openai: rate limited (429)"), "api_error")
        XCTAssertEqual(TelemetryRuntime.classifyError(""), "")
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
