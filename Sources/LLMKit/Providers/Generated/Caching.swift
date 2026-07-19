//


enum CachingMode: Sendable, Equatable {
    case automaticCaching
    case explicitCaching
    case resourceCaching
}

struct ResourceLifecycleDef: Sendable, Equatable {
    let createEndpoint: String
    let responseIdPath: String
    let referenceField: String
    let pollingEndpoint: String
    let pollingStatusPath: String
    let pollingDoneValue: String
    let pollingErrorValues: [String]
    let resultEndpoint: String
    let resultResponsePath: String
    let resultFileIdPath: String
    let fileContentEndpoint: String
}

struct CachingDef: Sendable, Equatable {
    let mode: CachingMode
    let controlType: String
    let writeTokensPath: String
    let readTokensPath: String
    let defaultTtl: String
    let lifecycle: ResourceLifecycleDef?
}

func cachingConfig(_ provider: ProviderName) -> CachingDef? {
    switch provider {
    case .anthropic:
        return CachingDef(
            mode: .explicitCaching,
            controlType: "ephemeral",
            writeTokensPath: "usage.cache_creation_input_tokens",
            readTokensPath: "usage.cache_read_input_tokens",
            defaultTtl: "300",
            lifecycle: nil
        )
    case .google:
        return CachingDef(
            mode: .resourceCaching,
            controlType: "",
            writeTokensPath: "",
            readTokensPath: "usageMetadata.cachedContentTokenCount",
            defaultTtl: "3600",
            lifecycle:
                ResourceLifecycleDef(
                    createEndpoint: "/v1beta/cachedContents",
                    responseIdPath: "name",
                    referenceField: "cachedContent",
                    pollingEndpoint: "",
                    pollingStatusPath: "",
                    pollingDoneValue: "",
                    pollingErrorValues: [],
                    resultEndpoint: "",
                    resultResponsePath: "",
                    resultFileIdPath: "",
                    fileContentEndpoint: ""
                )
        )
    case .openai:
        return CachingDef(
            mode: .automaticCaching,
            controlType: "",
            writeTokensPath: "",
            readTokensPath: "usage.prompt_tokens_details.cached_tokens",
            defaultTtl: "",
            lifecycle: nil
        )
    default: return nil
    }
}

func cacheUsagePaths(_ provider: ProviderName) -> (write: String, read: String) {
    if let config = cachingConfig(provider) {
        return (config.writeTokensPath, config.readTokensPath)
    }
    return ("", "")
}
