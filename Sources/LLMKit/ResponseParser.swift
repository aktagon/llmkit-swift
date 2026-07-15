import Foundation

///
///
///
enum ResponseParser {
    static func parse(config: ProviderSpec, body: Data) throws -> Response {
        guard let text = String(data: body, encoding: .utf8) else {
            throw LLMKitError.decoding("response body is not valid UTF-8")
        }
        let raw = try JSONValue.parse(text)

        let usage = Usage(
            input: raw.intValue(at: config.usageInputPath),
            output: raw.intValue(at: config.usageOutputPath),
            cacheWrite: config.cacheWritePath.isEmpty ? 0 : raw.intValue(at: config.cacheWritePath),
            cacheRead: config.cacheReadPath.isEmpty ? 0 : raw.intValue(at: config.cacheReadPath),
            reasoning: config.reasoningTokensPath.isEmpty ? 0 : raw.intValue(at: config.reasoningTokensPath),
            cost: config.usageCostPath.isEmpty
                ? 0.0
                : raw.doubleValue(at: config.usageCostPath) * config.usageCostScale
        )

        return Response(
            text: raw.stringValue(at: config.responseTextPath),
            usage: usage,
            finishReason: config.finishReasonPath.isEmpty ? "" : raw.stringValue(at: config.finishReasonPath),
            finishMessage: config.finishMessagePath.isEmpty ? "" : raw.stringValue(at: config.finishMessagePath),
            raw: nil
        )
    }

    ///
    ///
    static func parseError(config: ProviderSpec, statusCode: Int, body: Data) -> LLMKitError {
        let message = String(data: body, encoding: .utf8) ?? ""
        return .api(provider: config.slug, statusCode: statusCode, message: message)
    }
}
