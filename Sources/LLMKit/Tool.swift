import Foundation

/// A tool the model may invoke during an `Agent` loop. Handwritten (not
/// generated) because it carries a runtime `run` closure — the behavior the
/// ontology deliberately does not describe (ADR-050: generate data, not logic).
/// Mirror of Rust's `types.rs::Tool`.
public struct Tool: Sendable {
    /// The tool name the model selects and that a `ToolCall.name` matches.
    public let name: String

    /// A human-readable description the model uses to decide when to call it.
    public let description: String

    /// The JSON-Schema of the tool's arguments, embedded verbatim into the
    /// provider-specific tool-definition wire shape.
    public let schema: JSONValue

    /// The executor: receives the model-supplied argument object and returns the
    /// stringified result (or throws, surfaced to the model as an error string).
    /// `async` so blocking work (network, file IO — the normal tool body)
    /// suspends instead of starving the width-limited cooperative pool; the
    /// agent loop awaits each invocation. A synchronous closure still satisfies
    /// this type unchanged (Swift converts sync -> async at the call site), so
    /// pure-computation tools need no ceremony. Per-language idiom exception to
    /// the Go/Rust sync mirror, same class as Java's `await()` rename (ADR-021).
    public let run: @Sendable (JSONValue) async throws -> String

    public init(
        name: String,
        description: String,
        schema: JSONValue,
        run: @escaping @Sendable (JSONValue) async throws -> String
    ) {
        self.name = name
        self.description = description
        self.schema = schema
        self.run = run
    }
}
