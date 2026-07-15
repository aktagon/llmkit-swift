import Foundation

/// The lifecycle state of an async job (ADR-062 / ADR-063). PUBLIC because it is
/// what `poll` returns (POLL-004). Monotonic — `running -> (succeeded | failed)`.
/// No `unknown`/zero member by design (ADR-063 refinements 2).
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

/// The normalized failure detail carried by a `failed` status (ADR-062 §1): the
/// raw provider status, an optional provider error message, and a `timedOut`
/// flag. A typed cause enum is a non-breaking follow-up (slice 2).
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

/// The normalized result of a single `poll` (ADR-063 POLL-001): the state plus
/// the result XOR the failure cause. `result` is set iff `state == .succeeded`;
/// `cause` is set iff `state == .failed`.
public struct JobStatus<T: Sendable>: Sendable {
    public var state: JobState
    public var result: T?
    public var cause: JobFailure?
    public var rawStatus: String
}

/// The config half of the engine seam: classification facts + poll cadence.
struct LifecycleConfig {
    var noun: String
    var provider: String
    var id: String
    var statusPath: String
    var doneValues: [String]
    var errorValues: [String]
    var errorMessagePath: String
    /// Cadence between polls, in seconds. Zero = default (2s).
    var pollInterval: TimeInterval
    /// Wall-clock backstop for the poll LOOP, in seconds. Zero = no backstop.
    var pollTimeout: TimeInterval
}

/// The once-decoded provider poll response (S04). Confines the untyped JSON leaf.
struct PollBody {
    let raw: JSONValue

    func status(_ path: String) -> String { raw.stringValue(at: path) }
    func value() -> JSONValue { raw }
}

/// What `classify` returns: the state plus the failure detail when `failed`.
struct Classification {
    var state: JobState
    var failure: JobFailure?
    var rawStatus: String
}

/// The capability seams the engine cannot share (ADR-062 difference table).
/// `result` may perform a second network hop (batch's output_file_id -> GET
/// /content), so it is `async`.
protocol JobAdapter {
    associatedtype Out: Sendable
    var config: LifecycleConfig { get }
    func poll() async throws -> PollBody
    func classify(_ body: PollBody) throws -> Classification
    func result(_ body: PollBody) async throws -> Out
}

enum Job {
    /// The shared config-driven default classifier (ADR-062 §a). Precedence
    /// done > error > running: an unmodeled status stays `running` (bounded by
    /// the backstop), never a false terminal (ADR-062 refinements 4).
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

    /// One engine iteration: poll -> classify -> (on success) the capability
    /// result tail. This IS `poll()` made public; no loop, no deadline.
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

    /// The shared engine (ADR-062 §b). Loops `pollOnce` on the configured
    /// cadence until the first terminal classification or the deadline backstop
    /// (surfaced as the typed `LLMKitError.pollTimeout`, POLL-008).
    static func pollJob<A: JobAdapter>(_ adapter: A) async throws -> A.Out {
        let lc = adapter.config
        let interval = lc.pollInterval > 0 ? lc.pollInterval : 2
        let deadline = lc.pollTimeout > 0 ? Date().addingTimeInterval(lc.pollTimeout) : nil
        while true {
            let status = try await pollOnce(adapter)
            switch status.state {
            case .succeeded:
                // `pollOnce` sets `result` iff state is `.succeeded` (by
                // construction); guard rather than force-unwrap the invariant.
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

    /// Builds the error `pollJob` returns on a provider-reported terminal
    /// failure, preserving the capability's surface via `noun` (S02).
    private static func jobFailedError(_ noun: String, _ failure: JobFailure) -> LLMKitError {
        let detail = failure.message.isEmpty ? failure.status : failure.message
        return .unsupported(detail.isEmpty ? "\(noun) failed" : "\(noun) failed: \(detail)")
    }

    /// Filters out empty strings so a provider that leaves a status value unset
    /// contributes an empty set rather than a value matching a missing status.
    static func nonEmptyValues(_ values: [String]) -> [String] {
        values.filter { !$0.isEmpty }
    }
}
