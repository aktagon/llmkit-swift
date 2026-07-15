import Foundation

/// The capabilities a model can expose. `llm:Capability` instances in the
/// ontology; `ModelInfo.capabilities` is an array of these. Ontology-derived
/// per ADR-019 — never populated from provider wire data. Hand-written sibling
/// of the generated struct surface (mirrors Rust's `types.rs` `Capability`).
public enum Capability: String, Sendable, Hashable, CaseIterable {
    case chatCompletion = "chat_completion"
    case imageGeneration = "image_generation"
    case toolCalling = "tool_calling"
    case fileUpload = "file_upload"
    case batching
    case caching
    case reasoning
    case catalogue
}
