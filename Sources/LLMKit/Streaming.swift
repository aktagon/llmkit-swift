import Foundation

/// Streaming (SSE) text generation — a file-by-file port of Rust's `stream.rs`.
/// Builds the request body through the shared `RequestBuilder`, adds the
/// per-provider stream flag (+ `stream_options.include_usage` where the provider
/// requires it, BUG-028), and consumes the `event:` / `data:` frame stream,
/// invoking `onDelta` per text chunk and assembling the final `Response`.
enum Streamer {
    static func run(
        config: ProviderSpec,
        apiKey: String,
        model: String,
        system: String?,
        msgs: [Transforms.Msg],
        options: PromptOptions,
        http: HTTPClient,
        baseURLOverride: String?,
        onDelta: @Sendable (String) -> Void
    ) async throws -> Response {
        guard let stream = streamConfig(config.name) else {
            throw LLMKitError.validation(field: "provider", message: "streaming not supported: \(config.slug)")
        }

        var (bodyValue, headers) = try RequestBuilder.buildBody(
            config: config, wireShape: config.chatWireShape, apiKey: apiKey,
            model: model, system: system, msgs: msgs, tools: [], options: options
        )
        guard case var .object(body) = bodyValue else {
            throw LLMKitError.validation(field: "body", message: "request body is not an object")
        }
        if !stream.param.isEmpty {
            JSONObject.set(&body, stream.param, .bool(true))
        }
        // BUG-028: opt into a streamed usage frame where the provider requires it.
        if stream.usageOptIn {
            JSONObject.set(&body, "stream_options", .object([("include_usage", .bool(true))]))
        }
        bodyValue = .object(body)

        let url = streamURL(config: config, stream: stream, apiKey: apiKey, model: model, baseURLOverride: baseURLOverride)
        let (statusCode, lines) = try await http.openStream(url: url, body: bodyValue, headers: headers)

        if !(200..<300).contains(statusCode) {
            var raw = ""
            for try await line in lines { raw += line + "\n" }
            throw ResponseParser.parseError(config: config, statusCode: statusCode, body: Data(raw.utf8))
        }

        let (finishEvent, finishPath) = parseStreamFinishPath(config.streamFinishReasonPath)
        var fullText = ""
        var finishReason = ""
        // Nothing is reported until a usage frame arrives. Seeding with six
        // zeroes claimed every dimension was reported before the first byte.
        var usage = Usage()
        var currentEvent = ""

        for try await line in lines {
            if let event = strip(line, "event: ") {
                currentEvent = event
                continue
            }
            guard let data = strip(line, "data: ") else { continue }

            // Data-level done sentinel (e.g. OpenAI [DONE]) is literal, not JSON.
            if !stream.doneSignal.isEmpty, data == stream.doneSignal {
                return Response(text: fullText, usage: usage, finishReason: optString(finishReason), finishMessage: nil, raw: nil)
            }

            let parsed = try? JSONValue.parse(data)

            // ADR-013: capture the stream-time finish reason before any event-
            // level done return.
            if let parsed, !finishPath.isEmpty, finishEvent.isEmpty || finishEvent == currentEvent {
                let value = parsed.stringValue(at: finishPath)
                if !value.isEmpty, value != "FINISH_REASON_UNSPECIFIED" {
                    finishReason = value
                }
            }

            if stream.usesEventTypes, !stream.doneEvent.isEmpty, currentEvent == stream.doneEvent {
                return Response(text: fullText, usage: usage, finishReason: optString(finishReason), finishMessage: nil, raw: nil)
            }

            guard let parsed else { currentEvent = ""; continue }

            if stream.usesEventTypes {
                if currentEvent == stream.contentEvent {
                    let text = parsed.stringValue(at: stream.deltaTextPath)
                    if !text.isEmpty { fullText += text; onDelta(text) }
                }
                if currentEvent == stream.usageEvent {
                    usage.output = parsed.optInt(at: stream.usageOutputPath)
                    usage.input = parsed.optInt(at: stream.usageInputPath)
                }
            } else {
                let text = parsed.stringValue(at: stream.deltaTextPath)
                if !text.isEmpty { fullText += text; onDelta(text) }
                // Usage arrives in ONE late frame; every earlier frame carries
                // none. The gate is therefore "did this frame report it", not
                // "is the number big enough" — the old `> 0` test also threw
                // away a genuinely reported zero (AVAIL-001).
                if let value = parsed.optInt(at: stream.usageInputPath) { usage.input = value }
                if let value = parsed.optInt(at: stream.usageOutputPath) { usage.output = value }
            }
            currentEvent = ""
        }

        return Response(text: fullText, usage: usage, finishReason: optString(finishReason), finishMessage: nil, raw: nil)
    }

    /// Split `event_name:json.path` into its event-name prefix and the JSON
    /// path. Bare paths return ("", path); empty returns ("", "").
    private static func parseStreamFinishPath(_ p: String) -> (event: String, path: String) {
        if p.isEmpty { return ("", "") }
        if let idx = p.firstIndex(of: ":") {
            return (String(p[p.startIndex..<idx]), String(p[p.index(after: idx)...]))
        }
        return ("", p)
    }

    private static func strip(_ line: String, _ prefix: String) -> String? {
        line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : nil
    }

    private static func streamURL(
        config: ProviderSpec, stream: StreamDef, apiKey: String, model: String, baseURLOverride: String?
    ) -> String {
        if stream.endpoint.isEmpty {
            return RequestBuilder.buildURL(
                config: config, endpoint: config.endpoint, apiKey: apiKey, model: model, baseURLOverride: baseURLOverride
            )
        }
        var base = baseURLOverride ?? config.baseURL
        if !config.regionEnvVar.isEmpty, let region = ProcessInfo.processInfo.environment[config.regionEnvVar] {
            base = base.replacingOccurrences(of: "{region}", with: region)
        }
        var endpoint = stream.endpoint
            .replacingOccurrences(of: "{model}", with: model)
            .replacingOccurrences(of: "{apiKey}", with: apiKey)
        if config.authScheme == "QueryParamKey" {
            let separator = endpoint.contains("?") ? "&" : "?"
            endpoint += "\(separator)\(config.authQueryParam)=\(apiKey)"
        }
        return base + endpoint
    }
}
