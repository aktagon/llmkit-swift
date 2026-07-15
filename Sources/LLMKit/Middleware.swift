import Foundation

/// Middleware runtime — pre-phase veto + post-phase observation. A port of
/// Rust's `middleware.rs` together with the generated `Event` / `MiddlewareOp` /
/// `MiddlewarePhase` types (Swift handwrites these alongside the runtime, as it
/// does `Usage`, rather than emitting a separate generated constants module).
/// The handwritten capability runtimes fire middleware around each operation
/// site; user hooks observe every call and may veto in the pre phase.

/// Which side of an operation an `Event` describes.
public enum MiddlewarePhase: Sendable, Equatable {
    case pre
    case post
}

/// The operation an `Event` describes. Cases mirror the generated `MiddlewareOp`
/// (the `llm:MiddlewareOp` instances) across the other SDKs; the raw values are
/// the canonical op labels.
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

/// The observation record passed to each middleware hook. Fields beyond
/// op/provider/model/phase are populated only for the ops that carry them
/// (mirror of the generated `Event` struct).
public struct Event: Sendable {
    public var op: MiddlewareOp
    public var phase: MiddlewarePhase
    public var provider: String
    public var model: String
    /// Set only for `toolCall`.
    public var tool: String
    /// Set only for `toolCall`, pre phase.
    public var args: [String: JSONValue]
    /// Set only for `toolCall`, post phase.
    public var result: String
    /// Set for `llmRequest`, post phase.
    public var usage: Usage?
    /// Set in the post phase when the operation failed.
    public var err: String?
    /// Set in the post phase (wall-clock duration of the operation).
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

/// A user middleware hook. A non-nil PRE-phase return vetoes the operation
/// (surfaced as `MiddlewareVeto`); POST-phase return values are discarded.
public typealias MiddlewareFn = @Sendable (Event) -> (any Error)?

/// Wraps a pre-phase veto cause so callers can match on it
/// (`catch let veto as MiddlewareVeto`).
public struct MiddlewareVeto: Error {
    public let cause: any Error
    public init(cause: any Error) { self.cause = cause }
}

enum Middleware {
    /// Run pre-phase hooks in registration order; the first non-nil return
    /// aborts the operation and is thrown as `MiddlewareVeto`.
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

    /// Run post-phase hooks in registration order; return values are discarded
    /// (post is strictly observational).
    static func firePost(_ mws: [MiddlewareFn], _ base: Event) {
        if mws.isEmpty { return }
        var event = base
        event.phase = .post
        for hook in mws { _ = hook(event) }
    }
}
