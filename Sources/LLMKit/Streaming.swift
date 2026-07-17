import Foundation

///
///
///
///
///
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
        //
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
        var usage = Usage(input: 0, output: 0, cacheWrite: 0, cacheRead: 0, reasoning: 0, cost: 0)
        var currentEvent = ""

        for try await line in lines {
            if let event = strip(line, "event: ") {
                currentEvent = event
                continue
            }
            guard let data = strip(line, "data: ") else { continue }

            //
            if !stream.doneSignal.isEmpty, data == stream.doneSignal {
                return Response(text: fullText, usage: usage, finishReason: finishReason, finishMessage: "", raw: nil)
            }

            let parsed = try? JSONValue.parse(data)

            //
            //
            if let parsed, !finishPath.isEmpty, finishEvent.isEmpty || finishEvent == currentEvent {
                let value = parsed.stringValue(at: finishPath)
                if !value.isEmpty, value != "FINISH_REASON_UNSPECIFIED" {
                    finishReason = value
                }
            }

            if stream.usesEventTypes, !stream.doneEvent.isEmpty, currentEvent == stream.doneEvent {
                return Response(text: fullText, usage: usage, finishReason: finishReason, finishMessage: "", raw: nil)
            }

            guard let parsed else { currentEvent = ""; continue }

            if stream.usesEventTypes {
                if currentEvent == stream.contentEvent {
                    let text = parsed.stringValue(at: stream.deltaTextPath)
                    if !text.isEmpty { fullText += text; onDelta(text) }
                }
                if currentEvent == stream.usageEvent, !stream.usageOutputPath.isEmpty {
                    usage.output = parsed.intValue(at: stream.usageOutputPath)
                    if !stream.usageInputPath.isEmpty { usage.input = parsed.intValue(at: stream.usageInputPath) }
                }
            } else {
                let text = parsed.stringValue(at: stream.deltaTextPath)
                if !text.isEmpty { fullText += text; onDelta(text) }
                if !stream.usageInputPath.isEmpty {
                    let value = parsed.intValue(at: stream.usageInputPath)
                    if value > 0 { usage.input = value }
                }
                if !stream.usageOutputPath.isEmpty {
                    let value = parsed.intValue(at: stream.usageOutputPath)
                    if value > 0 { usage.output = value }
                }
            }
            currentEvent = ""
        }

        return Response(text: fullText, usage: usage, finishReason: finishReason, finishMessage: "", raw: nil)
    }

    ///
    ///
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
