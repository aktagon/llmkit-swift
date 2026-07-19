//


enum SystemPlacement: Sendable, Equatable {
    case topLevelField
    case messageInArray
    case siblingObject
}

enum AuthScheme: Sendable, Equatable {
    case bearerToken
    case headerApiKey
    case queryParamKey
    case sigV4
}

struct StructuredOutputDef: Sendable, Equatable {
    let formatField: String
    let formatType: String
    let schemaPath: String
    let betaHeader: String
    let enforceStrict: Bool
    let removeAdditionalProps: Bool
    let schemaPlacement: String
}

struct ToolCallDef: Sendable, Equatable {
    let argsFormat: String
    let resultRole: String
    let idSource: String
    let paramsWireField: String  // ADR-025
}

struct FileUploadDef: Sendable, Equatable {
    let endpoint: String
    let fieldName: String
    let extraFieldsJSON: String
    let betaHeader: String
    let responseIdPath: String
    let responseUriPath: String
    let responseNamePath: String
    let responseMimePath: String
    let refType: String
    let refIdField: String
    let refUriField: String
    let refMimeField: String
    let refExtraFieldsJSON: String
}

func authScheme(_ provider: ProviderName) -> AuthScheme {
    switch provider {
    case .ai21: return .bearerToken
    case .anthropic: return .headerApiKey
    case .assemblyai: return .headerApiKey
    case .azure: return .headerApiKey
    case .bedrock: return .sigV4
    case .cerebras: return .bearerToken
    case .cohere: return .bearerToken
    case .deepseek: return .bearerToken
    case .doubao: return .bearerToken
    case .ernie: return .bearerToken
    case .fireworks: return .bearerToken
    case .google: return .queryParamKey
    case .grok: return .bearerToken
    case .groq: return .bearerToken
    case .inworld: return .bearerToken
    case .jan: return .bearerToken
    case .llamacpp: return .bearerToken
    case .lmstudio: return .bearerToken
    case .minimax: return .bearerToken
    case .mistral: return .bearerToken
    case .moonshot: return .bearerToken
    case .ollama: return .bearerToken
    case .openai: return .bearerToken
    case .openrouter: return .bearerToken
    case .perplexity: return .bearerToken
    case .pixverse: return .headerApiKey
    case .qwen: return .bearerToken
    case .recraft: return .bearerToken
    case .sambanova: return .bearerToken
    case .together: return .bearerToken
    case .vertex: return .bearerToken
    case .vidu: return .bearerToken
    case .vllm: return .bearerToken
    case .workersai: return .bearerToken
    case .yi: return .bearerToken
    case .zhipu: return .bearerToken
    }
}

func systemPlacement(_ provider: ProviderName) -> SystemPlacement {
    switch provider {
    case .ai21: return .messageInArray
    case .anthropic: return .topLevelField
    case .assemblyai: return .messageInArray
    case .azure: return .messageInArray
    case .bedrock: return .topLevelField
    case .cerebras: return .messageInArray
    case .cohere: return .messageInArray
    case .deepseek: return .messageInArray
    case .doubao: return .messageInArray
    case .ernie: return .messageInArray
    case .fireworks: return .messageInArray
    case .google: return .siblingObject
    case .grok: return .messageInArray
    case .groq: return .messageInArray
    case .inworld: return .messageInArray
    case .jan: return .messageInArray
    case .llamacpp: return .messageInArray
    case .lmstudio: return .messageInArray
    case .minimax: return .messageInArray
    case .mistral: return .messageInArray
    case .moonshot: return .messageInArray
    case .ollama: return .messageInArray
    case .openai: return .messageInArray
    case .openrouter: return .messageInArray
    case .perplexity: return .messageInArray
    case .pixverse: return .messageInArray
    case .qwen: return .messageInArray
    case .recraft: return .messageInArray
    case .sambanova: return .messageInArray
    case .together: return .messageInArray
    case .vertex: return .messageInArray
    case .vidu: return .messageInArray
    case .vllm: return .messageInArray
    case .workersai: return .messageInArray
    case .yi: return .messageInArray
    case .zhipu: return .messageInArray
    }
}

func structuredOutput(_ provider: ProviderName) -> StructuredOutputDef? {
    switch provider {
    case .anthropic:
        return StructuredOutputDef(
            formatField: "output_format",
            formatType: "json_schema",
            schemaPath: "schema",
            betaHeader: "structured-outputs-2025-11-13",
            enforceStrict: true,
            removeAdditionalProps: false,
            schemaPlacement: "WrappedInFormat"
        )
    case .azure:
        return StructuredOutputDef(
            formatField: "response_format",
            formatType: "json_schema",
            schemaPath: "json_schema.schema",
            betaHeader: "",
            enforceStrict: true,
            removeAdditionalProps: false,
            schemaPlacement: "WrappedInFormat"
        )
    case .google:
        return StructuredOutputDef(
            formatField: "generationConfig.responseMimeType",
            formatType: "application/json",
            schemaPath: "generationConfig.responseSchema",
            betaHeader: "",
            enforceStrict: false,
            removeAdditionalProps: true,
            schemaPlacement: "SiblingOfFormat"
        )
    case .grok:
        return StructuredOutputDef(
            formatField: "response_format",
            formatType: "json_schema",
            schemaPath: "json_schema.schema",
            betaHeader: "",
            enforceStrict: true,
            removeAdditionalProps: false,
            schemaPlacement: "WrappedInFormat"
        )
    case .mistral:
        return StructuredOutputDef(
            formatField: "response_format",
            formatType: "json_schema",
            schemaPath: "json_schema.schema",
            betaHeader: "",
            enforceStrict: true,
            removeAdditionalProps: false,
            schemaPlacement: "WrappedInFormat"
        )
    case .openai:
        return StructuredOutputDef(
            formatField: "response_format",
            formatType: "json_schema",
            schemaPath: "json_schema.schema",
            betaHeader: "",
            enforceStrict: true,
            removeAdditionalProps: false,
            schemaPlacement: "WrappedInFormat"
        )
    default: return nil
    }
}

func toolCallConfig(_ provider: ProviderName) -> ToolCallDef? {
    switch provider {
    case .ai21:
        return ToolCallDef(
            argsFormat: "json_string",
            resultRole: "tool",
            idSource: "id_field",
            paramsWireField: "parameters"
        )
    case .anthropic:
        return ToolCallDef(
            argsFormat: "map",
            resultRole: "user",
            idSource: "id_field",
            paramsWireField: "parameters"
        )
    case .azure:
        return ToolCallDef(
            argsFormat: "json_string",
            resultRole: "tool",
            idSource: "id_field",
            paramsWireField: "parameters"
        )
    case .bedrock:
        return ToolCallDef(
            argsFormat: "map",
            resultRole: "user",
            idSource: "id_field",
            paramsWireField: "parameters"
        )
    case .cerebras:
        return ToolCallDef(
            argsFormat: "json_string",
            resultRole: "tool",
            idSource: "id_field",
            paramsWireField: "parameters"
        )
    case .cohere:
        return ToolCallDef(
            argsFormat: "json_string",
            resultRole: "tool",
            idSource: "id_field",
            paramsWireField: "parameters"
        )
    case .deepseek:
        return ToolCallDef(
            argsFormat: "json_string",
            resultRole: "tool",
            idSource: "id_field",
            paramsWireField: "parameters"
        )
    case .doubao:
        return ToolCallDef(
            argsFormat: "json_string",
            resultRole: "tool",
            idSource: "id_field",
            paramsWireField: "parameters"
        )
    case .ernie:
        return ToolCallDef(
            argsFormat: "json_string",
            resultRole: "tool",
            idSource: "id_field",
            paramsWireField: "parameters"
        )
    case .fireworks:
        return ToolCallDef(
            argsFormat: "json_string",
            resultRole: "tool",
            idSource: "id_field",
            paramsWireField: "parameters"
        )
    case .google:
        return ToolCallDef(
            argsFormat: "map",
            resultRole: "user",
            idSource: "function_name",
            paramsWireField: "parametersJsonSchema"
        )
    case .grok:
        return ToolCallDef(
            argsFormat: "json_string",
            resultRole: "tool",
            idSource: "id_field",
            paramsWireField: "parameters"
        )
    case .groq:
        return ToolCallDef(
            argsFormat: "json_string",
            resultRole: "tool",
            idSource: "id_field",
            paramsWireField: "parameters"
        )
    case .jan:
        return ToolCallDef(
            argsFormat: "json_string",
            resultRole: "tool",
            idSource: "id_field",
            paramsWireField: "parameters"
        )
    case .llamacpp:
        return ToolCallDef(
            argsFormat: "json_string",
            resultRole: "tool",
            idSource: "id_field",
            paramsWireField: "parameters"
        )
    case .lmstudio:
        return ToolCallDef(
            argsFormat: "json_string",
            resultRole: "tool",
            idSource: "id_field",
            paramsWireField: "parameters"
        )
    case .minimax:
        return ToolCallDef(
            argsFormat: "json_string",
            resultRole: "tool",
            idSource: "id_field",
            paramsWireField: "parameters"
        )
    case .mistral:
        return ToolCallDef(
            argsFormat: "json_string",
            resultRole: "tool",
            idSource: "id_field",
            paramsWireField: "parameters"
        )
    case .moonshot:
        return ToolCallDef(
            argsFormat: "json_string",
            resultRole: "tool",
            idSource: "id_field",
            paramsWireField: "parameters"
        )
    case .ollama:
        return ToolCallDef(
            argsFormat: "json_string",
            resultRole: "tool",
            idSource: "id_field",
            paramsWireField: "parameters"
        )
    case .openai:
        return ToolCallDef(
            argsFormat: "json_string",
            resultRole: "tool",
            idSource: "id_field",
            paramsWireField: "parameters"
        )
    case .openrouter:
        return ToolCallDef(
            argsFormat: "json_string",
            resultRole: "tool",
            idSource: "id_field",
            paramsWireField: "parameters"
        )
    case .qwen:
        return ToolCallDef(
            argsFormat: "json_string",
            resultRole: "tool",
            idSource: "id_field",
            paramsWireField: "parameters"
        )
    case .sambanova:
        return ToolCallDef(
            argsFormat: "json_string",
            resultRole: "tool",
            idSource: "id_field",
            paramsWireField: "parameters"
        )
    case .together:
        return ToolCallDef(
            argsFormat: "json_string",
            resultRole: "tool",
            idSource: "id_field",
            paramsWireField: "parameters"
        )
    case .vllm:
        return ToolCallDef(
            argsFormat: "json_string",
            resultRole: "tool",
            idSource: "id_field",
            paramsWireField: "parameters"
        )
    case .zhipu:
        return ToolCallDef(
            argsFormat: "json_string",
            resultRole: "tool",
            idSource: "id_field",
            paramsWireField: "parameters"
        )
    default: return nil
    }
}

func fileUploadConfig(_ provider: ProviderName) -> FileUploadDef? {
    switch provider {
    case .anthropic:
        return FileUploadDef(
            endpoint: "/v1/files",
            fieldName: "file",
            extraFieldsJSON: "",
            betaHeader: "files-api-2025-04-14",
            responseIdPath: "id",
            responseUriPath: "",
            responseNamePath: "filename",
            responseMimePath: "mime_type",
            refType: "document",
            refIdField: "source.file_id",
            refUriField: "",
            refMimeField: "",
            refExtraFieldsJSON: "{\"source\":{\"type\":\"file\"}}"
        )
    case .google:
        return FileUploadDef(
            endpoint: "/upload/v1beta/files",
            fieldName: "file",
            extraFieldsJSON: "",
            betaHeader: "",
            responseIdPath: "file.name",
            responseUriPath: "file.uri",
            responseNamePath: "file.displayName",
            responseMimePath: "file.mimeType",
            refType: "fileData",
            refIdField: "",
            refUriField: "fileData.fileUri",
            refMimeField: "fileData.mimeType",
            refExtraFieldsJSON: ""
        )
    case .grok:
        return FileUploadDef(
            endpoint: "/v1/files",
            fieldName: "file",
            extraFieldsJSON: "{\"purpose\":\"assistants\"}",
            betaHeader: "",
            responseIdPath: "id",
            responseUriPath: "",
            responseNamePath: "filename",
            responseMimePath: "",
            refType: "",
            refIdField: "",
            refUriField: "",
            refMimeField: "",
            refExtraFieldsJSON: ""
        )
    case .openai:
        return FileUploadDef(
            endpoint: "/v1/files",
            fieldName: "file",
            extraFieldsJSON: "{\"purpose\":\"assistants\"}",
            betaHeader: "",
            responseIdPath: "id",
            responseUriPath: "",
            responseNamePath: "filename",
            responseMimePath: "",
            refType: "file",
            refIdField: "file.file_id",
            refUriField: "",
            refMimeField: "",
            refExtraFieldsJSON: ""
        )
    default: return nil
    }
}
