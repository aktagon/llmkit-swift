import Foundation

///
///
///
public enum JobState: Sendable, Equatable, CustomStringConvertible {
    case running
    case succeeded
    case failed

    public var description: String {
        switch self {
        case .running: return "running"
        case .succeeded: return "succeeded"
        case .failed: return "failed"
        }
    }
}

///
///
///
public struct JobFailure: Sendable, Equatable {
    public var status: String
    public var message: String
    public var timedOut: Bool

    public init(status: String = "", message: String = "", timedOut: Bool = false) {
        self.status = status
        self.message = message
        self.timedOut = timedOut
    }
}

///
///
///
public struct JobStatus<T: Sendable>: Sendable {
    public var state: JobState
    public var result: T?
    public var cause: JobFailure?
    public var rawStatus: String
}

///
struct LifecycleConfig {
    var noun: String
    var provider: String
    var id: String
    var statusPath: String
    var doneValues: [String]
    var errorValues: [String]
    var errorMessagePath: String
    ///
    var pollInterval: TimeInterval
    ///
    var pollTimeout: TimeInterval
}

///
struct PollBody {
    let raw: JSONValue

    func status(_ path: String) -> String { raw.stringValue(at: path) }
    func value() -> JSONValue { raw }
}

///
struct Classification {
    var state: JobState
    var failure: JobFailure?
    var rawStatus: String
}

///
///
///
protocol JobAdapter {
    associatedtype Out: Sendable
    var config: LifecycleConfig { get }
    func poll() async throws -> PollBody
    func classify(_ body: PollBody) throws -> Classification
    func result(_ body: PollBody) async throws -> Out
}

enum Job {
    ///
    ///
    ///
    static func classifyByConfig(_ lc: LifecycleConfig, _ body: PollBody) -> Classification {
        let status = body.status(lc.statusPath)
        if lc.doneValues.contains(status) {
            return Classification(state: .succeeded, failure: nil, rawStatus: status)
        }
        if lc.errorValues.contains(status) {
            var failure = JobFailure(status: status)
            if !lc.errorMessagePath.isEmpty { failure.message = body.status(lc.errorMessagePath) }
            return Classification(state: .failed, failure: failure, rawStatus: status)
        }
        return Classification(state: .running, failure: nil, rawStatus: status)
    }

    ///
    ///
    static func pollOnce<A: JobAdapter>(_ adapter: A) async throws -> JobStatus<A.Out> {
        let body = try await adapter.poll()
        let classification = try adapter.classify(body)
        var status = JobStatus<A.Out>(
            state: classification.state, result: nil, cause: nil, rawStatus: classification.rawStatus
        )
        switch classification.state {
        case .succeeded: status.result = try await adapter.result(body)
        case .failed: status.cause = classification.failure
        case .running: break
        }
        return status
    }

    ///
    ///
    ///
    static func pollJob<A: JobAdapter>(_ adapter: A) async throws -> A.Out {
        let lc = adapter.config
        let interval = lc.pollInterval > 0 ? lc.pollInterval : 2
        let deadline = lc.pollTimeout > 0 ? Date().addingTimeInterval(lc.pollTimeout) : nil
        while true {
            let status = try await pollOnce(adapter)
            switch status.state {
            case .succeeded:
                //
                //
                guard let result = status.result else {
                    throw LLMKitError.unsupported("\(lc.noun): succeeded status carried no result")
                }
                return result
            case .failed:
                throw jobFailedError(lc.noun, status.cause ?? JobFailure())
            case .running:
                break
            }
            if let deadline, Date() > deadline {
                throw LLMKitError.pollTimeout(provider: lc.provider, id: lc.id)
            }
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }

    ///
    ///
    private static func jobFailedError(_ noun: String, _ failure: JobFailure) -> LLMKitError {
        let detail = failure.message.isEmpty ? failure.status : failure.message
        return .unsupported(detail.isEmpty ? "\(noun) failed" : "\(noun) failed: \(detail)")
    }

    ///
    ///
    static func nonEmptyValues(_ values: [String]) -> [String] {
        values.filter { !$0.isEmpty }
    }
}
