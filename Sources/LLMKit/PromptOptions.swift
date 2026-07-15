import Foundation

/// A per-request safety-setting pair (Google `safetySettings`). Public because
/// it is a builder argument (`Text.safetySettings([...])`).
public struct SafetySetting: Sendable, Equatable {
    public let category: String
    public let threshold: String

    public init(category: String, threshold: String) {
        self.category = category
        self.threshold = threshold
    }
}

/// The accumulated generation parameters carried by the `Text` builder and
/// applied to the request body by `RequestBuilder` (mirrors Rust's
/// `PromptOptions`). Internal — the public surface is the builder chain.
struct PromptOptions: Sendable {
    /// Opt into prompt caching (ADR-026). The provider-appropriate mechanism is
    /// chosen by `cachingConfig(provider).mode`.
    var caching: Bool = false
    /// Cache TTL in seconds (resource caching only); nil uses the provider default.
    var cacheTtl: Int?
    /// Observation + veto hooks fired around each operation site.
    var middleware: [MiddlewareFn] = []
    var maxTokens: Int?
    var temperature: Double?
    var topP: Double?
    var topK: Int?
    var seed: Int64?
    var frequencyPenalty: Double?
    var presencePenalty: Double?
    var thinkingBudget: Int?
    var reasoningEffort: String?
    var stopSequences: [String] = []
    var safetySettings: [SafetySetting] = []
    /// The chat-protocol opt-in token (ADR-055), e.g. "responses". Empty = default.
    var proto: String = ""
    /// A JSON-Schema string for structured output, or nil.
    var schema: String?
}
