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
    /// finishReason set to the provider's failure reason ("errored",
    /// "batch_expired", ...; `batchSlotError` when the provider gives none) and
    /// finishMessage set to the provider's error message. A request with no
    /// result line reads finishReason `batchSlotMissing`. Results whose request
    /// id is not one this SDK assigned (a batch created elsewhere, resumed by
    /// ID) follow the indexed ones in file order.
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
        options: PromptOptions,
        raw: Bool = false
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
                    items.append(.object([("custom_id", .string("\(batchRequestIdPrefix)\(index)")), (batch.itemBodyField, itemBody)]))
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
        let handle = BatchHandle(id: batchId, provider: config.name, raw: raw)
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
                ("custom_id", .string("\(batchRequestIdPrefix)\(index)")),
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

    /// Reads every result source the lifecycle declares (HANDOFF-078), in this
    /// order: the direct result endpoint (Anthropic), then the output file and
    /// the error file whose IDs the status body carries (OpenAI). A file ID
    /// that is absent is skipped; the call fails only when no source was read.
    /// The status body is the already-decoded poll body, so no status GET is
    /// needed; it also carries the request count that fixes the slot count.
    func result(_ body: PollBody) async throws -> [Response] {
        let status = body.value()
        var sources: [String] = []
        if !lifecycle.resultEndpoint.isEmpty {
            sources.append(try await fetch(
                base + lifecycle.resultEndpoint.replacingOccurrences(of: "{id}", with: lc.id)
            ))
        }
        for idPath in [lifecycle.resultFileIdPath, lifecycle.errorFileIdPath] where !idPath.isEmpty {
            let fileId = status.stringValue(at: idPath)
            if fileId.isEmpty { continue }
            sources.append(try await fetch(
                base + lifecycle.fileContentEndpoint.replacingOccurrences(of: "{id}", with: fileId)
            ))
        }
        guard !sources.isEmpty else {
            throw LLMKitError.unsupported("batch results: no result source for \(spec.slug) batch \(lc.id)")
        }
        return parseResults(sources, count: Self.requestCount(status, batch.requestCountPaths))
    }

    private func fetch(_ url: String) async throws -> String {
        let (status, data) = try await http.getText(url: url, headers: headers)
        guard (200..<300).contains(status) else {
            throw ResponseParser.parseError(config: spec, statusCode: status, body: data)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// The sum of the numbers at `paths` in the status body, or nil when no
    /// path resolves to a number.
    static func requestCount(_ status: JSONValue, _ paths: [String]) -> Int? {
        var total: Int?
        for path in paths {
            if let n = status.optTruncatedInt(at: path) { total = (total ?? 0) + n }
        }
        return total.map { max(0, $0) }
    }

    /// One parsed result line waiting for its index.
    private struct Slot {
        var response: Response
        var succeeded: Bool
    }

    /// One Response per submitted request, at that request's index (BUG-072,
    /// HANDOFF-078). Providers return result lines in any order, so a line is
    /// placed by the request id at `resultKeyPath`: `batchRequestIdPrefix` + N
    /// goes to index N. When one index appears twice, a line that succeeded
    /// replaces a failed one, a failed line never replaces a succeeded one, and
    /// otherwise the later line follows the indexed slots.
    ///
    /// With a request count there are exactly `count` slots, and an id at or
    /// above the count follows them. Without one, slots run to the highest
    /// index seen. An index with no line reads `batchSlotMissing`. Lines whose
    /// id has another form (a batch created outside llmkit) follow the indexed
    /// slots in source order. A line that is not JSON cannot be placed and is
    /// skipped.
    func parseResults(_ sources: [String], count: Int?) -> [Response] {
        var slots = [Slot?](repeating: nil, count: count ?? 0)
        var unkeyed: [Response] = []
        for data in sources {
            for rawLine in data.split(separator: "\n") {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.isEmpty { continue }
                guard let wrapper = try? JSONValue.parse(line) else { continue }
                let slot = parseResultLine(line, wrapper)

                guard !batch.resultKeyPath.isEmpty,
                      let index = Self.requestIndex(wrapper.lookup(batch.resultKeyPath)),
                      count.map({ index < $0 }) ?? true
                else {
                    unkeyed.append(slot.response)
                    continue
                }
                if index >= slots.count {
                    slots.append(contentsOf: [Slot?](repeating: nil, count: index - slots.count + 1))
                }
                switch slots[index] {
                case nil:
                    slots[index] = slot
                case let existing? where slot.succeeded && !existing.succeeded:
                    slots[index] = slot
                case let existing? where existing.succeeded && !slot.succeeded:
                    break  // The request succeeded; a failed duplicate adds nothing.
                default:
                    unkeyed.append(slot.response)
                }
            }
        }
        let missing = Response(
            text: "", usage: Usage(), finishReason: batchSlotMissing, finishMessage: nil, raw: nil
        )
        return slots.map { $0?.response ?? missing } + unkeyed
    }

    /// Decodes one result line. The line succeeded when the value at
    /// `resultStatusPath` is one of `resultSuccessValues` (any value when the
    /// provider declares no status path) and its body at `resultBodyPath` is a
    /// JSON object that decodes. Every other line is a failed Response: empty
    /// text, the first `resultReasonPaths` value as finishReason
    /// (`batchSlotError` when none resolves) and the first `resultMessagePaths`
    /// value as finishMessage. With raw on, a succeeded Response carries its
    /// body and a failed one the whole line.
    private func parseResultLine(_ line: String, _ wrapper: JSONValue) -> Slot {
        let signalled = batch.resultStatusPath.isEmpty
            || batch.resultSuccessValues.contains(wrapper.stringValue(at: batch.resultStatusPath))
        if signalled {
            // VERBATIM, not parse-navigate-re-serialize: the inner body is what
            // ADR-085 captures the assistant turn from, and serializing a parsed
            // tree emits the SDK's rendering, not the provider's.
            let body = batch.resultBodyPath.isEmpty
                ? line
                : ProviderTurnCapture.extractRawJSONPath(line, batch.resultBodyPath)
            // Batch is Chat-Completions-only (ADR-055): an empty wire shape
            // selects the provider's declared response paths, not the Responses
            // output[] arm.
            if let body, body.first == "{",
               let response = try? decodeResponseRaw(spec.name, "", Data(body.utf8), raw: raw) {
                return Slot(response: response, succeeded: true)
            }
        }
        let failed = Response(
            text: "",
            usage: Usage(),
            finishReason: Self.firstPath(wrapper, batch.resultReasonPaths) ?? batchSlotError,
            finishMessage: Self.firstPath(wrapper, batch.resultMessagePaths),
            raw: nil
        )
        return Slot(response: attachRaw(failed, raw: raw) { wrapper }, succeeded: false)
    }

    /// The value at the first path that resolves to a non-empty scalar,
    /// rendered as a string; nil when none does.
    private static func firstPath(_ value: JSONValue, _ paths: [String]) -> String? {
        paths.lazy.map { value.stringValue(at: $0) }.first { !$0.isEmpty }
    }

    /// N out of the `batchRequestIdPrefix` + N id the SDK sends with request
    /// N; nil for any other id.
    static func requestIndex(_ id: JSONValue?) -> Int? {
        guard case let .string(id)? = id, id.hasPrefix(batchRequestIdPrefix) else { return nil }
        let digits = id.dropFirst(batchRequestIdPrefix.count)
        guard !digits.isEmpty, digits.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        return Int(digits)
    }
}
