import Foundation

/// Hand-coded catalogue runtime (ADR-019). The `Models` / `ScopedModels` /
/// `Providers` builders (reached from `client.models` / `client.providers`)
/// delegate their terminals to the free functions in this file. Port of Rust's
/// `models.rs` + `builders/catalogue.rs`.
///
/// The generated data layer (`Catalogue.swift`, `ModelsParsers.swift`) supplies
/// the compiled-in table, the per-provider live-endpoint config, and the three
/// wire-shape parsers; everything with behaviour lives here.

/// Catalogue error sentinels (ADR-019). Live provider calls map to one of these
/// variants:
///
/// * `.notSupported` — provider lacks `llm:hasModelsEndpoint` (no `/v1/models`
///   route; nothing to fetch). Vertex and Bedrock surface this until their
///   dedicated parsers land.
/// * `.scope` — HTTP 403 whose body mentions scope (OpenAI's `api.model.read`
///   scope is the canonical case).
/// * `.unavailable` — any other non-2xx response or network failure during a
///   live HTTP call.
public enum CatalogueError: Error, Equatable {
    case notSupported
    case unavailable(String)
    case scope(String)

    /// Wire-format discriminant carried in `ProviderError.kind` (ADR-019
    /// Amendment 1). Lets consumers branch typed across all four SDKs via a
    /// single string compare.
    public var kind: String {
        switch self {
        case .notSupported: return "not_supported"
        case .unavailable: return "unavailable"
        case .scope: return "scope"
        }
    }

    /// Human-readable message carried in `ProviderError.message`.
    public var message: String {
        switch self {
        case .notSupported:
            return "llmkit: provider does not expose a models endpoint"
        case let .unavailable(detail):
            return "llmkit: provider models endpoint unavailable: \(detail)"
        case let .scope(detail):
            return "llmkit: api key lacks scope for models endpoint: \(detail)"
        }
    }
}

// MARK: - Builders

/// Models is the catalogue builder. Chain methods clone-on-chain and return a
/// fresh `Models`; `list` / `get` walk the compiled-in slice synchronously,
/// `live()` fans out HTTP across configured providers, `provider(p)` returns
/// `ScopedModels`.
public struct Models: Sendable {
    let client: Client
    var capFilter: Capability?

    init(client: Client) {
        self.client = client
        self.capFilter = nil
    }

    /// Filter the catalogue to models whose ontology-derived capabilities
    /// contain `c`. Composes with `list` / `live` / `provider(p).list`.
    public func withCapability(_ c: Capability) -> Models {
        var copy = self
        copy.capFilter = c
        return copy
    }

    /// Scope the catalogue to a single provider; returns `ScopedModels` on which
    /// `raw()`, `list()`, and `get(id)` are reachable. Credentials come from the
    /// client, so `p` supplies only the target provider identity.
    public func provider(_ p: ProviderName) -> ScopedModels {
        ScopedModels(client: client, target: p, capFilter: capFilter, rawFlag: false)
    }

    /// Returns the compiled-in catalogue, filtered by `withCapability` when set.
    /// Synchronous, no IO.
    public func list() -> [ModelInfo] {
        catalogueFilter(capFilter)
    }

    /// Returns a compiled-in model by id, or nil when no entry matches.
    public func get(_ id: String) -> ModelInfo? {
        catalogueLookup(id)
    }

    /// Walk every provider this client is credentialed for and return an
    /// aggregated `LiveResult`. Today a client carries one provider, so the
    /// result is 0 or 1 underlying calls; the shape leaves room for a future
    /// multi-credential client without breaking callers. `withCapability`
    /// composes post-fetch.
    public func live() async -> LiveResult {
        await catalogueRunLive(self)
    }
}

/// ScopedModels is the single-provider live-catalogue sub-builder. Reached via
/// `Models.provider(p)`. `raw()` opts into populating `ModelInfo.raw` per
/// ADR-014.
public struct ScopedModels: Sendable {
    let client: Client
    let target: ProviderName
    var capFilter: Capability?
    var rawFlag: Bool

    /// Opt into carrying the parsed provider-native record on each `ModelInfo`.
    public func raw() -> ScopedModels {
        var copy = self
        copy.rawFlag = true
        return copy
    }

    public func list() async throws -> [ModelInfo] {
        try await catalogueRunList(self)
    }

    public func get(_ id: String) async throws -> ModelInfo {
        try await catalogueRunGet(self, id)
    }
}

/// Providers is the providers-namespace prototype. `list()` returns the
/// providers with both credentials configured and `llm:hasModelsEndpoint`
/// declared, as secret-free `ProviderInfo` (ADR-040 PSR-005).
public struct Providers: Sendable {
    let client: Client

    public func list() -> [ProviderInfo] {
        catalogueProvidersList(client)
    }
}

// MARK: - Compiled-in runtime

/// Walk the compiled-in slice and return `ModelInfo` records matching the
/// optional capability filter.
func catalogueFilter(_ capFilter: Capability?) -> [ModelInfo] {
    compiledInModels
        .filter { model in
            guard let cap = capFilter else { return true }
            return model.capabilities.contains(cap)
        }
        .map(compiledToModelInfo)
}

/// Linear scan over the compiled-in slice. Returns nil on miss.
func catalogueLookup(_ id: String) -> ModelInfo? {
    compiledInModels.first(where: { $0.id == id }).map(compiledToModelInfo)
}

private func compiledToModelInfo(_ def: CompiledModelDef) -> ModelInfo {
    ModelInfo(
        id: def.id,
        provider: def.provider,
        capabilities: def.capabilities,
        displayName: def.displayName,
        description: def.description,
        contextWindow: def.contextWindow,
        maxOutput: def.maxOutput,
        created: 0,
        raw: nil
    )
}

// MARK: - Live runtime

/// Aggregate live results across configured providers. Errors land in
/// `result.errors` as typed `ProviderError` per Amendment 1. Sequential today —
/// a client carries one provider's credentials, so `n in {0, 1}`.
func catalogueRunLive(_ models: Models) async -> LiveResult {
    let configured = catalogueProvidersList(models.client)
    var all: [ModelInfo] = []
    var errors: [String: ProviderError] = [:]
    for info in configured {
        let scoped = ScopedModels(
            client: models.client, target: info.id,
            capFilter: models.capFilter, rawFlag: false
        )
        do {
            all.append(contentsOf: try await catalogueRunList(scoped))
        } catch let err as CatalogueError {
            errors[providerNameSlug(info.id)] = ProviderError(kind: err.kind, message: err.message)
        } catch {
            errors[providerNameSlug(info.id)] = ProviderError(kind: "unavailable", message: "\(error)")
        }
    }
    if let cap = models.capFilter {
        all = all.filter { $0.capabilities.contains(cap) }
    }
    all.sort { a, b in
        let pa = providerNameSlug(a.provider)
        let pb = providerNameSlug(b.provider)
        if pa != pb { return pa < pb }
        return a.id < b.id
    }
    return LiveResult(models: all, errors: errors)
}

/// Single-provider live HTTP. Paginates per the catalogue config until the
/// parser reports no next cursor, then enriches each record with the
/// ontology-derived capability list. Middleware fires once per call (not per
/// page) for observability at the call granularity.
func catalogueRunList(_ scoped: ScopedModels) async throws -> [ModelInfo] {
    guard let cfg = catalogueConfig(scoped.target) else { throw CatalogueError.notSupported }
    let pcfg = providerConfig(scoped.target)

    let baseEvent = Event(op: .modelsList, provider: providerNameSlug(scoped.target), model: "")
    do {
        try Middleware.firePre([], baseEvent)
    } catch {
        throw CatalogueError.unavailable("middleware veto: \(error)")
    }
    let records = try await paginate(scoped: scoped, pcfg: pcfg, cfg: cfg)
    Middleware.firePost([], baseEvent)
    return enrich(scoped, records)
}

/// Single-provider live model fetch. URL shapes pinned in plan 025 (Anthropic
/// `/v1/models/{id}`, OpenAI `/v1/models/{id}`, Google `/v1beta/models/{id}` —
/// the parser strips `models/` from the response, the URL uses the bare ID).
func catalogueRunGet(_ scoped: ScopedModels, _ id: String) async throws -> ModelInfo {
    guard let cfg = catalogueConfig(scoped.target) else { throw CatalogueError.notSupported }
    if cfg.parserKind == "ParseVertexModels" || cfg.parserKind == "ParseBedrockModels" {
        throw CatalogueError.notSupported
    }
    let pcfg = providerConfig(scoped.target)

    let baseEvent = Event(op: .modelsList, provider: providerNameSlug(scoped.target), model: id)
    do {
        try Middleware.firePre([], baseEvent)
    } catch {
        throw CatalogueError.unavailable("middleware veto: \(error)")
    }
    let endpointWithID = "\(cfg.endpoint)/\(id)"
    let body = try await fetchCatalogueURL(scoped: scoped, pcfg: pcfg, endpoint: endpointWithID)
    Middleware.firePost([], baseEvent)
    let record = try parseSingleRecord(cfg.parserKind, body)
    return enrich(scoped, [record])[0]
}

/// Providers-namespace runtime: the single credentialed provider, iff it
/// declares a live models endpoint.
func catalogueProvidersList(_ client: Client) -> [ProviderInfo] {
    if catalogueConfig(client.provider) == nil { return [] }
    return [providerInfo(client.provider)]
}

// MARK: - HTTP internals

private func paginate(
    scoped: ScopedModels, pcfg: ProviderSpec, cfg: CatalogueConfig
) async throws -> [ParsedModelRecord] {
    var cursor = ""
    var all: [ParsedModelRecord] = []
    while true {
        let endpoint = appendCursor(cfg.endpoint, cfg.cursorParam, cursor)
        let body = try await fetchCatalogueURL(scoped: scoped, pcfg: pcfg, endpoint: endpoint)
        let page = try dispatchParser(cfg.parserKind, body)
        all.append(contentsOf: page.records)
        if page.nextCursor.isEmpty { return all }
        cursor = page.nextCursor
    }
}

// Splices the pagination cursor into the URL using the cursor query-param
// name carried by the generated CatalogueConfig (ADR-067 Fix A). An empty
// cursor or an empty cursorParam (PaginationNone) leaves the URL unchanged.
private func appendCursor(_ endpoint: String, _ cursorParam: String, _ cursor: String) -> String {
    if cursor.isEmpty || cursorParam.isEmpty { return endpoint }
    let sep = endpoint.contains("?") ? "&" : "?"
    return "\(endpoint)\(sep)\(cursorParam)=\(urlencode(cursor))"
}

/// Minimal percent-encoder for the cursor-token use case; matches RFC 3986
/// unreserved characters.
private func urlencode(_ s: String) -> String {
    var out = ""
    for byte in s.utf8 {
        switch byte {
        case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x5F, 0x2E, 0x7E:
            out.unicodeScalars.append(UnicodeScalar(byte))
        default:
            out += String(format: "%%%02X", byte)
        }
    }
    return out
}

private func fetchCatalogueURL(
    scoped: ScopedModels, pcfg: ProviderSpec, endpoint: String
) async throws -> Data {
    let url = buildCatalogueURL(scoped: scoped, pcfg: pcfg, endpoint: endpoint)
    let headers = buildCatalogueHeaders(scoped: scoped, pcfg: pcfg)
    let statusCode: Int
    let data: Data
    do {
        (statusCode, data) = try await scoped.client.http.getText(url: url, headers: headers)
    } catch {
        throw CatalogueError.unavailable("\(error)")
    }
    if (200..<300).contains(statusCode) { return data }
    if statusCode == 403 && scopeBodyMatches(data) {
        throw CatalogueError.scope("status \(statusCode)")
    }
    throw CatalogueError.unavailable("status \(statusCode)")
}

private func scopeBodyMatches(_ body: Data) -> Bool {
    let lower = String(decoding: body, as: UTF8.self).lowercased()
    return lower.contains("scope") || lower.contains("permission")
}

private func buildCatalogueURL(
    scoped: ScopedModels, pcfg: ProviderSpec, endpoint: String
) -> String {
    let base = scoped.client.baseURLOverride ?? pcfg.baseURL
    var full = "\(base)\(endpoint)"
    if pcfg.authScheme == "QueryParamKey" {
        let sep = full.contains("?") ? "&" : "?"
        full = "\(full)\(sep)\(pcfg.authQueryParam)=\(urlencode(scoped.client.apiKey))"
    }
    return full
}

private func buildCatalogueHeaders(
    scoped: ScopedModels, pcfg: ProviderSpec
) -> [(String, String)] {
    var headers: [(String, String)] = []
    switch pcfg.authScheme {
    case "BearerToken":
        headers.append((pcfg.authHeader, "\(pcfg.authPrefix) \(scoped.client.apiKey)"))
    case "HeaderAPIKey":
        headers.append((pcfg.authHeader, scoped.client.apiKey))
    default:
        break // QueryParamKey / SigV4 — no auth header.
    }
    if !pcfg.requiredHeader.isEmpty {
        headers.append((pcfg.requiredHeader, pcfg.requiredHeaderValue))
    }
    return headers
}

private func dispatchParser(_ kind: String, _ body: Data) throws -> ParsedModelsPage {
    do {
        switch kind {
        case "ParseAnthropicModels": return try parseAnthropicModelsResponse(body)
        case "ParseGoogleModels": return try parseGoogleModelsResponse(body)
        case "ParseOpenAICohortModels": return try parseOpenAICohortModelsResponse(body)
        default: throw CatalogueError.notSupported
        }
    } catch let err as CatalogueError {
        throw err
    } catch {
        throw CatalogueError.unavailable("parse \(kind): \(error)")
    }
}

private func parseSingleRecord(_ kind: String, _ body: Data) throws -> ParsedModelRecord {
    let bodyStr = String(decoding: body, as: UTF8.self)
    let wrapped: String
    switch kind {
    case "ParseAnthropicModels": wrapped = "{\"data\":[\(bodyStr)]}"
    case "ParseGoogleModels": wrapped = "{\"models\":[\(bodyStr)]}"
    case "ParseOpenAICohortModels": wrapped = "{\"data\":[\(bodyStr)]}"
    default: throw CatalogueError.notSupported
    }
    let page = try dispatchParser(kind, Data(wrapped.utf8))
    guard let first = page.records.first else {
        throw CatalogueError.unavailable("empty single-record response")
    }
    return first
}

private func enrich(_ scoped: ScopedModels, _ records: [ParsedModelRecord]) -> [ModelInfo] {
    records.map { rec in
        let caps = ontologyCapabilities(scoped.target, rec.id) ?? []
        let raw = scoped.rawFlag ? rec.raw : nil
        return ModelInfo(
            id: rec.id,
            provider: scoped.target,
            capabilities: caps,
            displayName: rec.displayName,
            description: rec.description,
            contextWindow: rec.contextWindow,
            maxOutput: rec.maxOutput,
            created: rec.created,
            raw: raw
        )
    }
}

private func providerNameSlug(_ name: ProviderName) -> String {
    providerConfig(name).slug
}
