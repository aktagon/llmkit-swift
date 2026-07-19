//


///
///
///
public struct Usage: Sendable, Equatable {
    public var input: Int
    public var output: Int
    public var cacheWrite: Int
    public var cacheRead: Int
    public var reasoning: Int
    ///
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
