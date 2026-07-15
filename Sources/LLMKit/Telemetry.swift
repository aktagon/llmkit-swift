import Foundation

/// Opt-in observability (ADR-054 / ADR-059) — an OTEL GenAI-aligned OTLP span
/// built on every provider call and handed to a caller-supplied `export`. A port
/// of Rust's `telemetry.rs`. The generated telemetry constants (OTEL attribute
/// keys + the operation-name map) are handwritten here alongside the runtime, as
/// Swift already handwrites `Usage` and `MiddlewareOp` (the ontology data that
/// the other SDKs co-locate with runtime-coupled types); cross-SDK parity is held
/// by the telemetry-wire goldens (TEL-011), not by generation.

/// The OTEL GenAI binding facts + attribute mappings (ADR-054). Handwritten
/// (they reference the handwritten `MiddlewareOp`); a semantic-convention move
/// is an edit here + a re-anchored golden.
enum TelemetryConst {
    static let semconvVersion = "1.29.0"
    static let tracesPath = "/v1/traces"
    static let endpointRequired = true
    static let captureContentDefault = false

    // OTEL GenAI attribute keys (api:mapsToOtelAttribute).
    static let otelAttrOp = "gen_ai.operation.name"       // Event.op
    static let otelAttrProvider = "gen_ai.system"          // Event.provider
    static let otelAttrModel = "gen_ai.request.model"      // Event.model
    static let otelAttrErr = "error.type"                  // Event.err

    // OTEL GenAI usage attribute keys (llm:otelUsageAttribute).
    static let otelUsageInput = "gen_ai.usage.input_tokens"
    static let otelUsageOutput = "gen_ai.usage.output_tokens"

    /// Maps a `MiddlewareOp` to its `gen_ai.operation.name` value; ops without a
    /// documented semconv value return nil (honest).
    static func operationName(_ op: MiddlewareOp) -> String? {
        switch op {
        case .llmRequest: return "chat"
        case .toolCall: return "execute_tool"
        default: return nil
        }
    }
}

/// The telemetry export callback: receives the finished OTLP/HTTP proto3-JSON
/// bytes for one span, called synchronously on the post phase. Mandatory and
/// non-nil on `Telemetry`, so an enabled-but-no-sink config is unrepresentable
/// (the honest-contract lineage, ADR-059 TEL-017).
public typealias TelemetryExport = @Sendable (Data) -> Void

/// Opt-in observability config (ADR-059). Attach with `Client.addTelemetry`:
/// llmkit builds an OTEL GenAI-aligned OTLP span on every provider call and hands
/// the finished bytes to `export`. Off unless attached; `export` is required so
/// an enabled-but-no-sink config cannot be constructed.
public struct Telemetry: Sendable {
    /// Receives the finished OTLP bytes for one span (mandatory). Use
    /// `Telemetry.httpExport` for the batteries POST, or supply your own to
    /// bridge into an existing OTEL stack.
    public let export: TelemetryExport
    /// Gates tier-2 message payloads (default false for privacy). Reserved —
    /// content-log emission is a deferred follow-up (ADR-054 tier 2).
    public let captureContent: Bool

    public init(export: @escaping TelemetryExport, captureContent: Bool = false) {
        self.export = export
        self.captureContent = captureContent
    }

    /// A batteries export that POSTs each OTLP payload to `endpoint` + `/v1/traces`
    /// with the given headers, fail-open. Unlike the Rust twin (a synchronous
    /// std::net POST on the request path), the Swift transport is URLSession, so
    /// the POST is dispatched fire-and-forget — the request path never blocks on
    /// the collector, and every transport error is swallowed.
    public static func httpExport(endpoint: String, headers: [String: String] = [:]) -> TelemetryExport {
        let base = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
        let url = base + TelemetryConst.tracesPath
        return { payload in
            guard let target = URL(string: url) else { return }
            var request = URLRequest(url: target)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            request.httpBody = payload
            URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
        }
    }
}

enum TelemetryRuntime {
    /// Builds the export hook installed on the middleware seam. On the post phase
    /// it renders the OTLP payload and calls `export`; the pre phase is a no-op.
    /// Fail-open: an export error never surfaces to the caller.
    static func makeMiddleware(_ telemetry: Telemetry) -> MiddlewareFn {
        return { event in
            guard event.phase == .post else { return nil }
            telemetry.export(Data(buildPayload(event).utf8))
            return nil
        }
    }

    /// Classifies the post-phase `Event` and renders it to OTLP traces JSON. Span
    /// identity + timing are stamped here (the pure builder takes them as
    /// arguments so the parity goldens can inject fixed values).
    static func buildPayload(_ event: Event) -> String {
        let op = TelemetryConst.operationName(event.op) ?? "\(event.op)"
        let input = event.usage?.input ?? 0
        let output = event.usage?.output ?? 0
        let errorType = event.err.map(classifyError) ?? ""
        let now = String(UInt64(max(0, Date().timeIntervalSince1970)) * 1_000_000_000)
        return buildOTLPTraces(
            operationName: op, provider: event.provider, model: event.model,
            inputTokens: input, outputTokens: output, errorType: errorType,
            traceId: randHex(16), spanId: randHex(8), startNano: now, endNano: now
        )
    }

    /// The PURE, deterministic OTLP-payload builder (OTLP/HTTP, proto3-JSON).
    /// Given the call's primitives plus injectable span identity + timing, returns
    /// the exact JSON the exporter POSTs. The parity fixtures call it with fixed
    /// inputs so all five SDKs are asserted value-identical (TEL-011).
    ///
    /// Encoding notes (OTLP/JSON spec): int64 fields (times, token counts) render
    /// as strings; traceId/spanId are hex; each attribute value carries exactly
    /// one of stringValue XOR intValue; the span status is present only on error
    /// (code 2), omitted on success.
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
        if !errorType.isEmpty { attributes.append(stringAttr(TelemetryConst.otelAttrErr, errorType)) }

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

    /// int64 attributes render as a *string* intValue per the OTLP/JSON spec.
    private static func intAttr(_ key: String, _ value: Int) -> JSONValue {
        .object([("key", .string(key)), ("value", .object([("intValue", .string(String(value)))]))])
    }

    /// Maps a lossy `Event.err` message to a stable OTEL `error.type`. The typed
    /// error is erased at the middleware seam (`Event.err: String?`), so
    /// classification keys off the error-string prefixes. Best-effort — no wire
    /// golden asserts it (the rejection golden passes `error.type` directly).
    static func classifyError(_ err: String) -> String {
        if err.isEmpty { return "" }
        if err.hasPrefix("validation:") { return "validation_error" }
        if err.hasPrefix("http:") || err.hasPrefix("json:")
            || err.hasPrefix("unsupported:") || err.hasPrefix("middleware veto:") {
            return "error"
        }
        return "api_error"
    }

    /// A non-crypto hex string of `nBytes` bytes for span/trace identity. Ids are
    /// opaque to collectors, so `UUID`'s randomness is more than sufficient and
    /// keeps this stdlib-only.
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
