import Foundation

///
///
///
///
///
///
///

///
///
///
///
public typealias TelemetryExport = @Sendable (Data) -> Void

///
///
///
///
public struct Telemetry: Sendable {
    ///
    ///
    ///
    public let export: TelemetryExport
    ///
    ///
    public let captureContent: Bool

    public init(export: @escaping TelemetryExport, captureContent: Bool = false) {
        self.export = export
        self.captureContent = captureContent
    }

    ///
    ///
    ///
    ///
    ///
    ///
    ///
    ///
    ///
    ///
    ///
    public static func httpExport(
        endpoint: String, headers: [String: String] = [:], session: URLSession = .shared
    ) -> TelemetryExport {
        let base = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
        let url = base + TelemetryConst.tracesPath
        return { payload in
            guard let target = URL(string: url) else { return }
            var request = URLRequest(url: target)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            request.httpBody = payload
            session.dataTask(with: request) { _, _, _ in }.resume()
        }
    }
}

enum TelemetryRuntime {
    ///
    ///
    ///
    static func makeMiddleware(_ telemetry: Telemetry) -> MiddlewareFn {
        return { event in
            guard event.phase == .post else { return nil }
            telemetry.export(Data(buildPayload(event).utf8))
            return nil
        }
    }

    ///
    ///
    ///
    ///
    ///
    static func buildPayloadAt(
        _ event: Event, traceId: String, spanId: String, startNano: String, endNano: String
    ) -> String {
        let op = TelemetryConst.operationName(event.op) ?? "\(event.op)"
        let input = event.usage?.input ?? 0
        let output = event.usage?.output ?? 0
        return buildOTLPTraces(
            operationName: op, provider: event.provider, model: event.model,
            inputTokens: input, outputTokens: output, errorType: event.errType ?? "",
            traceId: traceId, spanId: spanId, startNano: startNano, endNano: endNano
        )
    }

    ///
    ///
    static func buildPayload(_ event: Event) -> String {
        let now = String(UInt64(max(0, Date().timeIntervalSince1970 * 1_000_000_000)))
        return buildPayloadAt(event, traceId: randHex(16), spanId: randHex(8), startNano: now, endNano: now)
    }

    ///
    ///
    ///
    ///
    ///
    ///
    ///
    ///
    ///
    static func buildOTLPTraces(
        operationName: String, provider: String, model: String,
        inputTokens: Int, outputTokens: Int, errorType: String,
        traceId: String, spanId: String, startNano: String, endNano: String
    ) -> String {
        var attributes: [JSONValue] = [
            stringAttr(TelemetryConst.otelAttrOp, operationName),
            stringAttr(TelemetryConst.otelAttrProvider, provider),
            stringAttr(TelemetryConst.otelAttrModel, model),
        ]
        if inputTokens > 0 { attributes.append(intAttr(TelemetryConst.otelUsageInput, inputTokens)) }
        if outputTokens > 0 { attributes.append(intAttr(TelemetryConst.otelUsageOutput, outputTokens)) }
        if !errorType.isEmpty { attributes.append(stringAttr(TelemetryConst.otelAttrErrType, errorType)) }

        var span: [(String, JSONValue)] = [
            ("traceId", .string(traceId)),
            ("spanId", .string(spanId)),
            ("name", .string("\(operationName) \(model)")),
            ("kind", .int(3)),
            ("startTimeUnixNano", .string(startNano)),
            ("endTimeUnixNano", .string(endNano)),
            ("attributes", .array(attributes)),
        ]
        if !errorType.isEmpty { span.append(("status", .object([("code", .int(2))]))) }

        let payload = JSONValue.object([
            ("resourceSpans", .array([.object([
                ("resource", .object([("attributes", .array([
                    stringAttr("service.name", "llmkit"),
                ]))])),
                ("scopeSpans", .array([.object([
                    ("scope", .object([
                        ("name", .string("llmkit")),
                        ("version", .string(TelemetryConst.semconvVersion)),
                    ])),
                    ("spans", .array([.object(span)])),
                ])])),
            ])])),
        ])
        return payload.serialized()
    }

    private static func stringAttr(_ key: String, _ value: String) -> JSONValue {
        .object([("key", .string(key)), ("value", .object([("stringValue", .string(value))]))])
    }

    ///
    private static func intAttr(_ key: String, _ value: Int) -> JSONValue {
        .object([("key", .string(key)), ("value", .object([("intValue", .string(String(value)))]))])
    }

    ///
    ///
    ///
    private static func randHex(_ nBytes: Int) -> String {
        var bytes: [UInt8] = []
        while bytes.count < nBytes {
            let u = UUID().uuid
            bytes.append(contentsOf: [
                u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7,
                u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15,
            ])
        }
        return bytes.prefix(nBytes).map { String(format: "%02x", $0) }.joined()
    }
}
