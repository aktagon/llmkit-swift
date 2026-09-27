// Code generated — DO NOT EDIT.


// Batch contract constants shared by every SDK (ADR-091).

/// Prefix + the request index is the id sent with each batch request.
let batchRequestIdPrefix = "req-"
/// `finishReason` of a batch slot whose request has no result line.
public let batchSlotMissing = "missing"
/// `finishReason` of a failed batch slot when the provider gives no reason.
public let batchSlotError = "error"

enum BatchInputMode: Sendable, Equatable {
    case inlineRequests
    case fileReferenceInput
}

struct BatchDef: Sendable, Equatable {
    let inputMode: BatchInputMode
    let inputField: String
    let filePurpose: String
    let requestWrapper: String
    let completionWindow: String
    let endpointPath: String
    let itemBodyField: String
    let resultBodyPath: String
    let resultKeyPath: String
    let resultStatusPath: String
    let resultSuccessValues: [String]
    let resultReasonPaths: [String]
    let resultMessagePaths: [String]
    let requestCountPaths: [String]
    let lifecycle: ResourceLifecycleDef?
}

func batchConfig(_ provider: ProviderName) -> BatchDef? {
    switch provider {
    case .anthropic:
        return BatchDef(
            inputMode: .inlineRequests,
            inputField: "",
            filePurpose: "",
            requestWrapper: "requests",
            completionWindow: "",
            endpointPath: "",
            itemBodyField: "params",
            resultBodyPath: "result.message",
            resultKeyPath: "custom_id",
            resultStatusPath: "result.type",
            resultSuccessValues: ["succeeded"],
            resultReasonPaths: ["result.type"],
            resultMessagePaths: ["result.error.error.message"],
            requestCountPaths: ["request_counts.processing", "request_counts.succeeded", "request_counts.errored", "request_counts.canceled", "request_counts.expired"],
            lifecycle:
                ResourceLifecycleDef(
                    createEndpoint: "/v1/messages/batches",
                    responseIdPath: "id",
                    referenceField: "",
                    pollingEndpoint: "",
                    pollingStatusPath: "processing_status",
                    pollingDoneValue: "ended",
                    pollingErrorValues: [],
                    resultEndpoint: "/v1/messages/batches/{id}/results",
                    resultResponsePath: "",
                    resultFileIdPath: "",
                    errorFileIdPath: "",
                    fileContentEndpoint: ""
                )
        )
    case .google:
        return BatchDef(
            inputMode: .inlineRequests,
            inputField: "",
            filePurpose: "",
            requestWrapper: "requests",
            completionWindow: "",
            endpointPath: "",
            itemBodyField: "",
            resultBodyPath: "",
            resultKeyPath: "",
            resultStatusPath: "",
            resultSuccessValues: [],
            resultReasonPaths: [],
            resultMessagePaths: [],
            requestCountPaths: [],
            lifecycle: nil
        )
    case .openai:
        return BatchDef(
            inputMode: .fileReferenceInput,
            inputField: "input_file_id",
            filePurpose: "batch",
            requestWrapper: "",
            completionWindow: "24h",
            endpointPath: "/v1/chat/completions",
            itemBodyField: "",
            resultBodyPath: "response.body",
            resultKeyPath: "custom_id",
            resultStatusPath: "response.status_code",
            resultSuccessValues: ["200"],
            resultReasonPaths: ["error.code", "response.body.error.code"],
            resultMessagePaths: ["error.message", "response.body.error.message"],
            requestCountPaths: ["request_counts.total"],
            lifecycle:
                ResourceLifecycleDef(
                    createEndpoint: "/v1/batches",
                    responseIdPath: "id",
                    referenceField: "",
                    pollingEndpoint: "",
                    pollingStatusPath: "status",
                    pollingDoneValue: "completed",
                    pollingErrorValues: ["failed", "expired", "cancelled"],
                    resultEndpoint: "",
                    resultResponsePath: "",
                    resultFileIdPath: "output_file_id",
                    errorFileIdPath: "error_file_id",
                    fileContentEndpoint: "/v1/files/{id}/content"
                )
        )
    default: return nil
    }
}
