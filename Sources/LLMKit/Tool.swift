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
    public let run: @Sendable (JSONValue) throws -> String

    public init(
        name: String,
        description: String,
        schema: JSONValue,
        run: @escaping @Sendable (JSONValue) throws -> String
    ) {
        self.name = name
        self.description = description
        self.schema = schema
        self.run = run
    }
}
