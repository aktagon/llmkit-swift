// Code generated — DO NOT EDIT.


/// Token consumption metrics for a generation call. Each dimension is
///
/// hand-written Response / Event structs reference it by name.
///
/// A dimension is either reported — carrying a value that may legitimately be
/// zero — or not reported at all. The two are different claims: a provider
/// that says it used no cached tokens and a provider that never mentions
/// caching are not the same fact, and neither is a zero.
public struct Usage: Sendable, Equatable {
    public var input: Int?
    public var output: Int?
    public var cacheWrite: Int?
    public var cacheRead: Int?
    public var reasoning: Int?
    /// cost is the provider-reported request cost in USD (ADR-027). Not a TokenDimension — a distinct monetary field. Only OpenRouter (the request must opt in with usage: {include: true}) and xAI report it. Providers whose usageCostPath is empty never report cost, and the field is then ABSENT, not 0.0 — an unreported cost is not a free request (ADR-081 AVAIL-007).
    public var cost: Double?

    public init(
        input: Int? = nil,
        output: Int? = nil,
        cacheWrite: Int? = nil,
        cacheRead: Int? = nil,
        reasoning: Int? = nil,
        cost: Double? = nil
    ) {
        self.input = input
        self.output = output
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
        self.reasoning = reasoning
        self.cost = cost
    }
}
