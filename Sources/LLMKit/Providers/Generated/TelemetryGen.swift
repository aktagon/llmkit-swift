//


///
///
///
enum TelemetryConst {
    static let semconvVersion = "1.29.0"
    static let tracesPath = "/v1/traces"
    static let endpointRequired = true
    static let captureContentDefault = false

    //
    static let otelAttrOp = "gen_ai.operation.name"  // Event.op
    static let otelAttrProvider = "gen_ai.system"  // Event.provider
    static let otelAttrModel = "gen_ai.request.model"  // Event.model
    static let otelAttrErrType = "error.type"  // Event.errType

    //
    static let otelUsageInput = "gen_ai.usage.input_tokens"
    static let otelUsageOutput = "gen_ai.usage.output_tokens"

    ///
    ///
    static func operationName(_ op: MiddlewareOp) -> String? {
        switch op {
        case .llmRequest: return "chat"
        case .toolCall: return "execute_tool"
        default: return nil
        }
    }
}
