import XCTest
@testable import LLMKit

///
///
///
///
///
///
final class TelemetryTests: XCTestCase {
    ///
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

        //
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

        //
        //
        struct Boom: Error {}
        let client = Client(provider: .openai, apiKey: "key", session: MockURLProtocol.makeSession())
            .addTelemetry(Telemetry(export: { _ in _ = Boom() }))
        let response = try await client.text.model("gpt-4o").prompt("Capital of Finland?")
        XCTAssertEqual(response.text, "Helsinki")
    }

    ///
    ///
    ///
    ///
    ///
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

    ///
    ///
    ///
    ///
    ///
    func testErrTypeStructuralClassification() {
        let api = LLMKitError.api(provider: "openai", statusCode: 429, message: "rate limited")
        XCTAssertEqual(Middleware.errString(api), "openai: rate limited (429)")
        XCTAssertEqual(Middleware.errType(api), "api_error")

        let validation = LLMKitError.validation(field: "model", message: "no model configured for openai")
        XCTAssertEqual(Middleware.errString(validation), "validation: model - no model configured for openai")
        XCTAssertEqual(Middleware.errType(validation), "validation_error")

        let transport = LLMKitError.transport("connection reset by peer")
        XCTAssertEqual(Middleware.errType(transport), "error")

        let decoding = LLMKitError.decoding("response carried no choices")
        XCTAssertEqual(Middleware.errType(decoding), "error")

        let unsupported = LLMKitError.unsupported("batch create: empty batch ID")
        XCTAssertEqual(Middleware.errString(unsupported), "unsupported: batch create: empty batch ID")
        XCTAssertEqual(Middleware.errType(unsupported), "error")

        struct RateLimitPolicy: Error {}
        let veto = MiddlewareVeto(cause: RateLimitPolicy())
        XCTAssertTrue(Middleware.errString(veto).hasPrefix("middleware veto: "))
        XCTAssertEqual(Middleware.errType(veto), "error")
    }

    ///
    ///
    func testSetErrorStampsErrAndErrTypeTogether() {
        var event = Event(op: .llmRequest, provider: "openai", model: "gpt-4o", phase: .post)
        Middleware.setError(
            &event, LLMKitError.validation(field: "caching", message: "not supported by grok")
        )
        XCTAssertEqual(event.err, "validation: caching - not supported by grok")
        XCTAssertEqual(event.errType, "validation_error")
    }

    ///
    ///
    ///
    ///
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

    ///
    ///
    ///
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

    ///
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
