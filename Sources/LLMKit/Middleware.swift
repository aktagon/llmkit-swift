import Foundation

///
///
///
///
///
///

///
public enum MiddlewarePhase: Sendable, Equatable {
    case pre
    case post
}

///
///
///
public enum MiddlewareOp: String, Sendable, Equatable {
    case llmRequest = "llm_request"
    case toolCall = "tool_call"
    case cacheCreate = "cache_create"
    case upload = "upload"
    case batchSubmit = "batch_submit"
    case imageGeneration = "image_generation"
    case musicGeneration = "music_generation"
    case videoGeneration = "video_generation"
    case modelsList = "models_list"
}

///
///
///
public struct Event: Sendable {
    public var op: MiddlewareOp
    public var phase: MiddlewarePhase
    public var provider: String
    public var model: String
    ///
    public var tool: String
    ///
    public var args: [String: JSONValue]
    ///
    public var result: String
    ///
    public var usage: Usage?
    ///
    public var err: String?
    ///
    public var duration: TimeInterval?

    public init(
        op: MiddlewareOp,
        provider: String,
        model: String,
        phase: MiddlewarePhase = .pre,
        tool: String = "",
        args: [String: JSONValue] = [:],
        result: String = "",
        usage: Usage? = nil,
        err: String? = nil,
        duration: TimeInterval? = nil
    ) {
        self.op = op
        self.provider = provider
        self.model = model
        self.phase = phase
        self.tool = tool
        self.args = args
        self.result = result
        self.usage = usage
        self.err = err
        self.duration = duration
    }
}

///
///
public typealias MiddlewareFn = @Sendable (Event) -> (any Error)?

///
///
public struct MiddlewareVeto: Error {
    public let cause: any Error
    public init(cause: any Error) { self.cause = cause }
}

enum Middleware {
    ///
    ///
    static func firePre(_ mws: [MiddlewareFn], _ base: Event) throws {
        if mws.isEmpty { return }
        var event = base
        event.phase = .pre
        for hook in mws {
            if let cause = hook(event) {
                throw MiddlewareVeto(cause: cause)
            }
        }
    }

    ///
    ///
    static func firePost(_ mws: [MiddlewareFn], _ base: Event) {
        if mws.isEmpty { return }
        var event = base
        event.phase = .post
        for hook in mws { _ = hook(event) }
    }
}
