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
///
///
///
///
///
///
///
public enum CatalogueError: Error, Equatable {
    case notSupported
    case unavailable(String)
    case scope(String)

    ///
    ///
    ///
    public var kind: String {
        switch self {
        case .notSupported: return "not_supported"
        case .unavailable: return "unavailable"
        case .scope: return "scope"
        }
    }

    ///
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

//

///
///
///
///
public struct Models: Sendable {
    let client: Client
    var capFilter: Capability?

    init(client: Client) {
        self.client = client
        self.capFilter = nil
    }

    ///
    ///
    public func withCapability(_ c: Capability) -> Models {
        var copy = self
        copy.capFilter = c
        return copy
    }

    ///
    ///
    ///
    public func provider(_ p: ProviderName) -> ScopedModels {
        ScopedModels(client: client, target: p, capFilter: capFilter, rawFlag: false)
    }

    ///
    ///
    public func list() -> [ModelInfo] {
        catalogueFilter(capFilter)
    }

    ///
    public func get(_ id: String) -> ModelInfo? {
        catalogueLookup(id)
    }

    ///
    ///
    ///
    ///
    ///
    public func live() async -> LiveResult {
        await catalogueRunLive(self)
    }
}

///
///
///
public struct ScopedModels: Sendable {
    let client: Client
    let target: ProviderName
    var capFilter: Capability?
    var rawFlag: Bool

    ///
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

///
///
///
public struct Providers: Sendable {
    let client: Client

    public func list() -> [ProviderInfo] {
        catalogueProvidersList(client)
    }
}

//

///
///
///
///
///
func applyCapFilter(_ models: [ModelInfo], _ capFilter: Capability?) -> [ModelInfo] {
    guard let cap = capFilter else { return models }
    return models.filter { $0.capabilities.contains(cap) }
}

///
func catalogueFilter(_ capFilter: Capability?) -> [ModelInfo] {
    applyCapFilter(compiledInModels.map(compiledToModelInfo), capFilter)
}

///
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

//

///
///
///
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
    //
    //
    all.sort { a, b in
        let pa = providerNameSlug(a.provider)
        let pb = providerNameSlug(b.provider)
        if pa != pb { return pa < pb }
        return a.id < b.id
    }
    return LiveResult(models: all, errors: errors)
}

///
///
///
///
///
///
func catalogueRunList(_ scoped: ScopedModels) async throws -> [ModelInfo] {
    guard let cfg = catalogueConfig(scoped.target) else { throw CatalogueError.notSupported }
    let pcfg = providerConfig(scoped.target)

    let mws = scoped.client.defaultMiddleware
    let baseEvent = Event(op: .modelsList, provider: providerNameSlug(scoped.target), model: "")
    let start = Date()
    do {
        try Middleware.firePre(mws, baseEvent)
    } catch {
        throw CatalogueError.unavailable(Middleware.errString(error))
    }
    var postEvent = baseEvent
    do {
        let records = try await paginate(scoped: scoped, pcfg: pcfg, cfg: cfg)
        postEvent.duration = Date().timeIntervalSince(start)
        Middleware.firePost(mws, postEvent)
        return applyCapFilter(enrich(scoped, records), scoped.capFilter)
    } catch {
        postEvent.duration = Date().timeIntervalSince(start)
        Middleware.setError(&postEvent, error)
        Middleware.firePost(mws, postEvent)
        throw error
    }
}

///
///
///
func catalogueRunGet(_ scoped: ScopedModels, _ id: String) async throws -> ModelInfo {
    guard let cfg = catalogueConfig(scoped.target) else { throw CatalogueError.notSupported }
    if cfg.parserKind == "ParseVertexModels" || cfg.parserKind == "ParseBedrockModels" {
        throw CatalogueError.notSupported
    }
    let pcfg = providerConfig(scoped.target)

    let mws = scoped.client.defaultMiddleware
    let baseEvent = Event(op: .modelsList, provider: providerNameSlug(scoped.target), model: id)
    let start = Date()
    do {
        try Middleware.firePre(mws, baseEvent)
    } catch {
        throw CatalogueError.unavailable(Middleware.errString(error))
    }
    var postEvent = baseEvent
    let body: Data
    do {
        body = try await fetchCatalogueURL(scoped: scoped, pcfg: pcfg, endpoint: "\(cfg.endpoint)/\(id)")
        postEvent.duration = Date().timeIntervalSince(start)
        Middleware.firePost(mws, postEvent)
    } catch {
        postEvent.duration = Date().timeIntervalSince(start)
        Middleware.setError(&postEvent, error)
        Middleware.firePost(mws, postEvent)
        throw error
    }
    let record = try parseSingleRecord(cfg.parserKind, body)
    return enrich(scoped, [record])[0]
}

///
///
func catalogueProvidersList(_ client: Client) -> [ProviderInfo] {
    if catalogueConfig(client.provider) == nil { return [] }
    return [providerInfo(client.provider)]
}

//

private func paginate(
    scoped: ScopedModels, pcfg: ProviderSpec, cfg: CatalogueConfig
) async throws -> [ParsedModelRecord] {
    var cursor = ""
    var all: [ParsedModelRecord] = []
    while true {
        let body = try await fetchCatalogueURL(
            scoped: scoped, pcfg: pcfg, endpoint: cfg.endpoint,
            cursor: cursor, cursorParam: cfg.cursorParam
        )
        let page = try dispatchParser(cfg.parserKind, body)
        all.append(contentsOf: page.records)
        if page.nextCursor.isEmpty { return all }
        cursor = page.nextCursor
    }
}

//
//
//
//
//
//
func appendCursor(_ rawURL: String, _ cursorParam: String, _ cursor: String) -> String {
    if cursor.isEmpty || cursorParam.isEmpty { return rawURL }
    let sep = rawURL.contains("?") ? "&" : "?"
    return "\(rawURL)\(sep)\(cursorParam)=\(urlencode(cursor))"
}

private func fetchCatalogueURL(
    scoped: ScopedModels, pcfg: ProviderSpec, endpoint: String,
    cursor: String = "", cursorParam: String = ""
) async throws -> Data {
    //
    //
    //
    let url = appendCursor(
        buildCatalogueURL(scoped: scoped, pcfg: pcfg, endpoint: endpoint),
        cursorParam, cursor
    )
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

func buildCatalogueURL(
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

func buildCatalogueHeaders(
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
