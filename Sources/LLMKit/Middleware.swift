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
    ///
    public var err: String?
    ///
    ///
    ///
    public var errType: String?
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
        errType: String? = nil,
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
        self.errType = errType
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

    ///
    ///
    ///
    ///
    ///
    ///
    static func errString(_ error: any Error) -> String {
        if let veto = error as? MiddlewareVeto {
            return "middleware veto: \(errString(veto.cause))"
        }
        if let known = error as? LLMKitError {
            //
            //
            if case let .unsupported(message) = known {
                return "unsupported: \(message)"
            }
            return known.errorDescription ?? "\(known)"
        }
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return "\(error)"
    }

    ///
    ///
    ///
    ///
    ///
    static func errType(_ error: any Error) -> String {
        if error is MiddlewareVeto { return "error" }
        if let known = error as? LLMKitError {
            switch known {
            case .api: return "api_error"
            case .validation: return "validation_error"
            case .transport, .decoding, .unsupported, .pollTimeout: return "error"
            }
        }
        return "error"
    }

    ///
    ///
    ///
    ///
    static func setError(_ event: inout Event, _ error: any Error) {
        event.err = errString(error)
        event.errType = errType(error)
    }
}
