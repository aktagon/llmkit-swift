import Foundation

/// Batch execution mode (ADR-064) — a port of Rust's `batch.rs` onto the shared
/// Job engine (ADR-062). `Text.batch(...)` submits and returns a `BatchJob`; the
/// job polls the lifecycle to completion and returns the ordered `[Response]`.
///
/// The generated `BatchHandle` value carries only identity (id + provider +
/// raw) — Swift maps `llm:Provider` to `ProviderName` (Phase-1 decision), so the
/// credential-bearing, transport-holding *live* handle is a handwritten wrapper
/// (`BatchJob`) around it. `BatchJob.handle` is the persistable value for
/// cross-process resume (ADR-014).
public final class BatchJob {
    /// The persistable identity value (ADR-014 cross-process resume).
    public let handle: BatchHandle
    let apiKey: String
    let http: HTTPClient
    let baseURLOverride: String?
    /// Poll cadence for `wait` (tests shrink these; defaults match Rust/Go).
    var interval: TimeInterval = 2
    var timeout: TimeInterval = 600

    init(handle: BatchHandle, apiKey: String, http: HTTPClient, baseURLOverride: String?) {
        self.handle = handle
        self.apiKey = apiKey
        self.http = http
        self.baseURLOverride = baseURLOverride
    }

    /// One normalized poll round-trip (ADR-063 POLL-001): no loop.
    public func poll() async throws -> JobStatus<[Response]> {
        try await Job.pollOnce(try makeAdapter())
    }

    /// Poll until a terminal state, returning the ordered responses.
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
        prompts: [String],
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
            let jsonl = try buildJSONL(prompts: prompts, config: config, apiKey: apiKey, model: model, options: options, batch: batch)
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
                let (itemBody, itemHeaders) = try RequestBuilder.buildBody(
                    config: config, wireShape: config.chatWireShape, apiKey: apiKey,
                    model: model, system: nil, msgs: [.text(role: "user", text: prompt)], tools: [], options: options
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

    private static func buildJSONL(
        prompts: [String], config: ProviderSpec, apiKey: String, model: String,
        options: PromptOptions, batch: BatchDef
    ) throws -> Data {
        var lines = ""
        for (index, prompt) in prompts.enumerated() {
            let (body, _) = try RequestBuilder.buildBody(
                config: config, wireShape: config.chatWireShape, apiKey: apiKey,
                model: model, system: nil, msgs: [.text(role: "user", text: prompt)], tools: [], options: options
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
            file: ("file", "batch_input.jsonl", data),
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
        return try parseResults(responseBody)
    }

    private func parseResults(_ data: String) throws -> [Response] {
        var responses: [Response] = []
        for rawLine in data.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let responseText: String
            if batch.resultBodyPath.isEmpty {
                responseText = line
            } else {
                let parsed = try JSONValue.parse(line)
                guard let inner = navigate(parsed, batch.resultBodyPath) else {
                    throw LLMKitError.unsupported("batch result wrapper missing body path")
                }
                responseText = inner.serialized()
            }
            responses.append(try ResponseParser.parse(config: spec, body: Data(responseText.utf8)))
        }
        return responses
    }

    private func navigate(_ value: JSONValue, _ path: String) -> JSONValue? {
        var current: JSONValue? = value
        for part in path.split(separator: ".") {
            current = current?.member(String(part))
        }
        return current
    }
}
