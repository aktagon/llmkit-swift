import Foundation

/// Batch execution mode (ADR-064) — a port of Rust's `batch.rs` onto the shared
/// Job engine (ADR-062). `Text.batch(...)` submits and returns a `BatchJob`; the
/// job polls the lifecycle to completion and returns the ordered `[Response]`.
///
/// The generated `BatchHandle` value carries only identity (id + provider +
/// raw) — Swift maps `Provider` to `ProviderName` (Phase-1 decision), so the
/// credential-bearing, transport-holding *live* handle is a handwritten wrapper
/// (`BatchJob`) around it. `BatchJob.handle` is the persistable value for
/// cross-process resume (ADR-014).
public final class BatchJob: Sendable {
    /// The persistable identity value (ADR-014 cross-process resume).
    public let handle: BatchHandle
    let apiKey: String
    let http: HTTPClient
    let baseURLOverride: String?
    /// Poll cadence for `wait` (tests shrink these via `cadence`; defaults match Rust/Go).
    let interval: TimeInterval
    let timeout: TimeInterval

    init(
        handle: BatchHandle, apiKey: String, http: HTTPClient, baseURLOverride: String?,
        interval: TimeInterval = 2, timeout: TimeInterval = 600
    ) {
        self.handle = handle
        self.apiKey = apiKey
        self.http = http
        self.baseURLOverride = baseURLOverride
        self.interval = interval
        self.timeout = timeout
    }

    /// A copy with the same identity + transport and the given poll cadence
    /// (internal test seam).
    func cadence(interval: TimeInterval, timeout: TimeInterval) -> BatchJob {
        BatchJob(
            handle: handle, apiKey: apiKey, http: http, baseURLOverride: baseURLOverride,
            interval: interval, timeout: timeout
        )
    }

    /// One normalized poll round-trip (ADR-063 POLL-001): no loop.
    public func poll() async throws -> JobStatus<[Response]> {
        try await Job.pollOnce(try makeAdapter())
    }

    /// Poll until a terminal state, returning one Response per prompt, at the
    /// prompt's index. A failed request keeps its slot: empty text,
    /// finishReason set to the provider's result status ("errored",
    /// "expired", "canceled"; "error" when the provider has none) and
    /// finishMessage set to the provider's error message. A request with no
    /// result line reads finishReason "missing". Results whose request id is
    /// not one this SDK assigned (a batch created elsewhere, resumed by ID)
    /// follow the indexed ones in file order.
    public func wait() async throws -> [Response] {
        var adapter = try makeAdapter()
        adapter.lc.pollInterval = interval
        adapter.lc.pollTimeout = timeout
        return try await Job.pollJob(adapter)
    }

    private func makeAdapter() throws -> BatchAdapter {
        try BatchAdapter(
            provider: handle.provider, apiKey: apiKey, http: http,
            baseURLOverride: baseURLOverride, id: handle.id, raw: handle.raw
        )
    }
}

enum Batch {
    /// Submit a batch of single-turn prompts and return the live `BatchJob`.
    static func submit(
        config: ProviderSpec,
        apiKey: String,
        http: HTTPClient,
        baseURLOverride: String?,
        model: String,
        system: String?,
        prompts: [String],
        images: [InputImage] = [],
        files: [FileRef] = [],
        history: [Transforms.Msg] = [],
        options: PromptOptions
    ) async throws -> BatchJob {
        guard let batch = batchConfig(config.name) else {
            throw LLMKitError.validation(field: "provider", message: "batching not supported: \(config.slug)")
        }
        guard let lifecycle = batch.lifecycle else {
            throw LLMKitError.validation(field: "provider", message: "async batching not supported: \(config.slug)")
        }
        let base = baseURLOverride ?? config.baseURL
        var headers = RequestBuilder.buildAuthHeaders(config: config, apiKey: apiKey)

        let body: JSONValue
        switch batch.inputMode {
        case .fileReferenceInput:
            let jsonl = try await buildJSONL(
                prompts: prompts, config: config, apiKey: apiKey, model: model,
                system: system, images: images, files: files, history: history,
                options: options,
                batch: batch, http: http, baseURLOverride: baseURLOverride
            )
            let fileId = try await uploadFile(base: base, headers: headers, batch: batch, data: jsonl, http: http)
            body = .object([
                (batch.inputField, .string(fileId)),
                ("endpoint", .string(batch.endpointPath)),
                ("completion_window", .string(batch.completionWindow)),
            ])
        case .inlineRequests:
            var items: [JSONValue] = []
            // The per-item bodies may require a contract-bearing anthropic-beta
            // (structured output / files) that buildAuthHeaders does not set —
            // compose it across items and ride it onto the batch CREATE request,
            // else a schema/file-referencing item silently drops the beta and the
            // provider 400s (mirror of Rust batch.rs build_batch_body).
            var beta = ""
            for (index, prompt) in prompts.enumerated() {
                var (itemBody, itemHeaders) = try RequestBuilder.buildBody(
                    config: config, wireShape: config.chatWireShape, apiKey: apiKey,
                    model: model, system: system, msgs: itemMsgs(prompt, images: images, files: files, history: history),
                    tools: [], options: options
                )
                try await CachingRuntime.apply(
                    &itemBody, provider: config.name, model: model, apiKey: apiKey,
                    options: options, config: config, http: http, baseURLOverride: baseURLOverride
                )
                if let value = itemHeaders.first(where: { $0.0.caseInsensitiveCompare("anthropic-beta") == .orderedSame })?.1 {
                    beta = RequestBuilder.appendBeta(beta, value)
                }
                if batch.itemBodyField.isEmpty {
                    items.append(itemBody)
                } else {
                    items.append(.object([("custom_id", .string("req-\(index)")), (batch.itemBodyField, itemBody)]))
                }
            }
            if !beta.isEmpty {
                if let existing = headers.firstIndex(where: { $0.0.caseInsensitiveCompare("anthropic-beta") == .orderedSame }) {
                    headers[existing].1 = RequestBuilder.appendBeta(headers[existing].1, beta)
                } else {
                    headers.append(("anthropic-beta", beta))
                }
            }
            body = batch.requestWrapper.isEmpty
                ? .object([("requests", .array(items))])
                : .object([(batch.requestWrapper, .array(items))])
        }

        let url = base + lifecycle.createEndpoint
        let (status, responseBody) = try await http.postJSON(url: url, body: body, headers: headers)
        guard (200..<300).contains(status) else {
            throw ResponseParser.parseError(config: config, statusCode: status, body: responseBody)
        }
        let parsed = try JSONValue.parse(String(decoding: responseBody, as: UTF8.self))
        let batchId = parsed.stringValue(at: lifecycle.responseIdPath)
        guard !batchId.isEmpty else {
            throw LLMKitError.unsupported("batch create: empty batch ID")
        }
        let handle = BatchHandle(id: batchId, provider: config.name, raw: false)
        return BatchJob(handle: handle, apiKey: apiKey, http: http, baseURLOverride: baseURLOverride)
    }

    /// The per-item user turn — a media turn when the builder carried image/file
    /// parts (ADR-060), else a plain text turn. Batch applies the builder's media
    /// to every item (the ADR-064 `batch(prompts...)` shape carries builder-level
    /// config uniformly).
    private static func itemMsgs(
        _ prompt: String, images: [InputImage], files: [FileRef], history: [Transforms.Msg]
    ) -> [Transforms.Msg] {
        let turn: Transforms.Msg = images.isEmpty && files.isEmpty
            ? .text(role: "user", text: prompt)
            : .media(role: "user", text: prompt, images: images, files: files)
        return history + [turn]
    }

    private static func buildJSONL(
        prompts: [String], config: ProviderSpec, apiKey: String, model: String,
        system: String?, images: [InputImage], files: [FileRef], history: [Transforms.Msg],
        options: PromptOptions,
        batch: BatchDef, http: HTTPClient, baseURLOverride: String?
    ) async throws -> Data {
        var lines = ""
        for (index, prompt) in prompts.enumerated() {
            var (body, _) = try RequestBuilder.buildBody(
                config: config, wireShape: config.chatWireShape, apiKey: apiKey,
                model: model, system: system, msgs: itemMsgs(prompt, images: images, files: files, history: history),
                tools: [], options: options
            )
            try await CachingRuntime.apply(
                &body, provider: config.name, model: model, apiKey: apiKey,
                options: options, config: config, http: http, baseURLOverride: baseURLOverride
            )
            let line = JSONValue.object([
                ("custom_id", .string("req-\(index)")),
                ("method", .string("POST")),
                ("url", .string(batch.endpointPath)),
                ("body", body),
            ])
            lines += line.serialized() + "\n"
        }
        return Data(lines.utf8)
    }

    private static func uploadFile(
        base: String, headers: [(String, String)], batch: BatchDef, data: Data, http: HTTPClient
    ) async throws -> String {
        let (status, body) = try await http.postMultipart(
            url: base + "/v1/files",
            fields: [("purpose", batch.filePurpose)],
            file: ("file", "batch_input.jsonl", "application/octet-stream", data),
            headers: headers
        )
        guard (200..<300).contains(status) else {
            throw LLMKitError.api(provider: "batch_file_upload", statusCode: status, message: String(decoding: body, as: UTF8.self))
        }
        let parsed = try JSONValue.parse(String(decoding: body, as: UTF8.self))
        let fileId = parsed.stringValue(at: "id")
        guard !fileId.isEmpty else { throw LLMKitError.unsupported("batch file upload: empty file ID") }
        return fileId
    }
}

/// Binds the batch capability to the Job engine's four seams.
struct BatchAdapter: JobAdapter {
    var lc: LifecycleConfig
    var config: LifecycleConfig { lc }
    let providerName: ProviderName
    let spec: ProviderSpec
    let base: String
    let headers: [(String, String)]
    let batch: BatchDef
    let lifecycle: ResourceLifecycleDef
    let pollURL: String
    let raw: Bool
    let http: HTTPClient

    init(provider: ProviderName, apiKey: String, http: HTTPClient, baseURLOverride: String?, id: String, raw: Bool) throws {
        let config = providerConfig(provider)
        guard let batch = batchConfig(provider) else {
            throw LLMKitError.validation(field: "provider", message: "batching not supported: \(config.slug)")
        }
        guard let lifecycle = batch.lifecycle else {
            throw LLMKitError.validation(field: "provider", message: "async batching not supported: \(config.slug)")
        }
        let base = baseURLOverride ?? config.baseURL
        let headers = RequestBuilder.buildAuthHeaders(config: config, apiKey: apiKey)
        let pollURL = lifecycle.pollingEndpoint.isEmpty
            ? "\(base)\(lifecycle.createEndpoint)/\(id)"
            : base + lifecycle.pollingEndpoint.replacingOccurrences(of: "{id}", with: id)

        self.providerName = provider
        self.spec = config
        self.base = base
        self.headers = headers
        self.batch = batch
        self.lifecycle = lifecycle
        self.pollURL = pollURL
        self.raw = raw
        self.http = http
        self.lc = LifecycleConfig(
            noun: "batch",
            provider: config.slug,
            id: id,
            statusPath: lifecycle.pollingStatusPath,
            doneValues: Job.nonEmptyValues([lifecycle.pollingDoneValue]),
            errorValues: Job.nonEmptyValues(lifecycle.pollingErrorValues),
            errorMessagePath: "",
            pollInterval: 2,
            pollTimeout: 600
        )
    }

    func poll() async throws -> PollBody {
        let (status, body) = try await http.getText(url: pollURL, headers: headers)
        guard (200..<300).contains(status) else {
            throw ResponseParser.parseError(config: spec, statusCode: status, body: body)
        }
        return PollBody(raw: try JSONValue.parse(String(decoding: body, as: UTF8.self)))
    }

    func classify(_ body: PollBody) throws -> Classification {
        Job.classifyByConfig(lc, body)
    }

    func result(_ body: PollBody) async throws -> [Response] {
        // The output file ID lives in the already-decoded poll body (S1) — no
        // redundant status GET.
        let responseBody: String
        if !lifecycle.resultFileIdPath.isEmpty {
            let fileId = body.value().stringValue(at: lifecycle.resultFileIdPath)
            guard !fileId.isEmpty else { throw LLMKitError.unsupported("batch results: empty output file ID") }
            let url = base + lifecycle.fileContentEndpoint.replacingOccurrences(of: "{id}", with: fileId)
            let (status, data) = try await http.getText(url: url, headers: headers)
            guard (200..<300).contains(status) else {
                throw ResponseParser.parseError(config: spec, statusCode: status, body: data)
            }
            responseBody = String(decoding: data, as: UTF8.self)
        } else if !lifecycle.resultEndpoint.isEmpty {
            let url = base + lifecycle.resultEndpoint.replacingOccurrences(of: "{id}", with: lc.id)
            let (status, data) = try await http.getText(url: url, headers: headers)
            guard (200..<300).contains(status) else {
                throw ResponseParser.parseError(config: spec, statusCode: status, body: data)
            }
            responseBody = String(decoding: data, as: UTF8.self)
        } else {
            throw LLMKitError.unsupported("batch result endpoint not configured for \(spec.slug)")
        }
        return parseResults(responseBody)
    }

    /// One Response per submitted request, at that request's index (BUG-072).
    /// Providers return result lines in any order, so a line is placed by the
    /// request id at `resultKeyPath`: "req-N" goes to index N. A line with no
    /// decodable body at `resultBodyPath` is a failed request and keeps its
    /// slot (see `parseResultLine`). An index with no line reads finishReason
    /// "missing". Lines whose id is not "req-N" (a batch created outside
    /// llmkit, or a repeated id) follow the indexed slots in file order. A line
    /// that is not JSON cannot be placed and is skipped; its index reads
    /// "missing".
    func parseResults(_ data: String) -> [Response] {
        var slots: [Response?] = []
        var unkeyed: [Response] = []
        for rawLine in data.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            guard let wrapper = try? JSONValue.parse(line) else { continue }
            let response = parseResultLine(line, wrapper)

            guard !batch.resultKeyPath.isEmpty,
                  let index = Self.requestIndex(wrapper.lookup(batch.resultKeyPath)),
                  index >= slots.count || slots[index] == nil
            else {
                unkeyed.append(response)
                continue
            }
            if index >= slots.count {
                slots.append(contentsOf: Array(repeating: nil, count: index - slots.count + 1))
            }
            slots[index] = response
        }
        let missing = Response(
            text: "", usage: Usage(), finishReason: "missing", finishMessage: nil, raw: nil
        )
        return slots.map { $0 ?? missing } + unkeyed
    }

    /// Decodes one result line. A line whose body is missing at
    /// `resultBodyPath`, or does not decode, becomes a failed Response: empty
    /// text, finishReason from `resultStatusPath` ("error" when the provider
    /// has none), finishMessage from `resultErrorPath`.
    private func parseResultLine(_ line: String, _ wrapper: JSONValue) -> Response {
        // VERBATIM, not parse-navigate-re-serialize: the inner body is what
        // ADR-085 captures the assistant turn from, and serializing a parsed
        // tree emits the SDK's rendering, not the provider's. Harmless while
        // only scalars were read out of it; not harmless once a payload is
        // captured from the same bytes.
        let body = batch.resultBodyPath.isEmpty
            ? line
            : ProviderTurnCapture.extractRawJSONPath(line, batch.resultBodyPath)
        // Batch is Chat-Completions-only (ADR-055): an empty wire shape
        // selects the provider's declared response paths, not the Responses
        // output[] arm.
        if let body, body.first == "{",
           let response = try? decodeResponse(spec.name, "", Data(body.utf8)) {
            return response
        }
        return Response(
            text: "",
            usage: Usage(),
            finishReason: Self.string(wrapper, batch.resultStatusPath) ?? "error",
            finishMessage: Self.string(wrapper, batch.resultErrorPath),
            raw: nil
        )
    }

    /// A non-empty string at `path`, or nil (also when `path` is empty).
    private static func string(_ value: JSONValue, _ path: String) -> String? {
        guard !path.isEmpty, case let .string(s)? = value.lookup(path), !s.isEmpty else { return nil }
        return s
    }

    /// N out of the "req-N" id the SDK sends with request N; nil for any other id.
    static func requestIndex(_ id: JSONValue?) -> Int? {
        guard case let .string(id)? = id, id.hasPrefix("req-") else { return nil }
        let digits = id.dropFirst(4)
        guard !digits.isEmpty, digits.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        return Int(digits)
    }
}
