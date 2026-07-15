import Foundation

/// Request-body transforms, selected by the generated `chatWireShape` fact
/// (ADR-047 / ADR-055 discriminator), NOT by provider name. Phase 0 implements
/// only the flat `ChatOpenAI` shape (single-turn user prompt); other shapes are
/// rejected until their slice lands.
enum Transforms {
    /// Append the provider-specific messages array to `body`. Phase 0: a single
    /// user turn plus, when the provider places system content in the message
    /// array, a leading system turn.
    static func applyMessageShape(
        body: inout [(String, JSONValue)],
        userPrompt: String,
        system: String?,
        config: ProviderSpec
    ) {
        var messages: [JSONValue] = []
        if config.systemPlacement == "MessageInArray",
           let system, !system.isEmpty {
            messages.append(.object([
                ("role", .string(mapRole("system", config))),
                ("content", .string(system)),
            ]))
        }
        messages.append(.object([
            ("role", .string(mapRole("user", config))),
            ("content", .string(userPrompt)),
        ]))
        body.append(("messages", .array(messages)))
    }

    /// Translate a canonical role to the provider's wire role (identity when the
    /// provider declares no mapping).
    static func mapRole(_ role: String, _ config: ProviderSpec) -> String {
        config.roleMappings[role] ?? role
    }
}
