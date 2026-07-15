import Foundation

/// Token consumption metrics for a generation call. Hand-written sibling of the
/// generated `Response` struct (which references it by name), mirroring Rust's
/// `types.rs` `Usage` referenced from the generated `structs.rs`. Each dimension
/// is populated from the provider-specific path declared in the ontology.
public struct Usage: Sendable, Equatable {
    public var input: Int
    public var output: Int
    public var cacheWrite: Int
    public var cacheRead: Int
    public var reasoning: Int
    /// Provider-reported cost (USD); 0.0 when unreported (ADR-027).
    public var cost: Double

    public init(
        input: Int = 0,
        output: Int = 0,
        cacheWrite: Int = 0,
        cacheRead: Int = 0,
        reasoning: Int = 0,
        cost: Double = 0.0
    ) {
        self.input = input
        self.output = output
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
        self.reasoning = reasoning
        self.cost = cost
    }
}
