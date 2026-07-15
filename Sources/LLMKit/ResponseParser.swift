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

        //
        //
        let (cacheWritePath, cacheReadPath) = cacheUsagePaths(config.name)
        let costPath = usageCostPath(config.name)

        let usage = Usage(
            input: raw.intValue(at: config.usageInputPath),
            output: raw.intValue(at: config.usageOutputPath),
            cacheWrite: cacheWritePath.isEmpty ? 0 : raw.intValue(at: cacheWritePath),
            cacheRead: cacheReadPath.isEmpty ? 0 : raw.intValue(at: cacheReadPath),
            reasoning: config.reasoningTokensPath.isEmpty ? 0 : raw.intValue(at: config.reasoningTokensPath),
            cost: costPath.isEmpty
                ? 0.0
                : raw.doubleValue(at: costPath) * usageCostScale(config.name)
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
    ///
    static func parseError(config: ProviderSpec, statusCode: Int, body: Data) -> LLMKitError {
        let raw = String(data: body, encoding: .utf8) ?? ""
        var message = raw
        if !config.errorMessagePath.isEmpty,
           let parsed = try? JSONValue.parse(raw) {
            let extracted = parsed.stringValue(at: config.errorMessagePath)
            if !extracted.isEmpty { message = extracted }
        }
        return .api(provider: config.slug, statusCode: statusCode, message: message)
    }
}
