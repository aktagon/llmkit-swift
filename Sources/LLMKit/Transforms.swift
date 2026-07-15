import Foundation

/// Request-body message transforms, selected by the effective `chatWireShape`
/// (ADR-047 / ADR-055 discriminator), NOT by provider name — mirror of Rust's
/// `transforms.rs::apply_message_shape`. Phase 2 covers the single-turn user
/// path for the three chat array shapes: Google `contents`/`parts`, OpenAI
/// Responses `input`, and the flat `messages` shape (OpenAI/Anthropic/Bedrock).
/// Multi-turn history, media Parts, and tool defs land in later phases.
enum Transforms {
    /// Append the provider-specific message array to `body`.
    static func applyMessageShape(
        body: inout [(String, JSONValue)],
        userPrompt: String,
        system: String?,
        wireShape: String,
        config: ProviderSpec
    ) {
        if wireShape == "ChatGoogle" {
            transformGoogleParts(body: &body, userPrompt: userPrompt, config: config)
        } else if wireShape == "ChatResponsesOpenAI" {
            JSONObject.set(
                &body, "input",
                .array(flatMessageArray(userPrompt: userPrompt, system: system, wireShape: wireShape, config: config))
            )
        } else {
            JSONObject.set(
                &body, "messages",
                .array(flatMessageArray(userPrompt: userPrompt, system: system, wireShape: wireShape, config: config))
            )
        }
    }

    /// The shared flat message array used by both the Chat Completions
    /// ("messages") and Responses ("input") envelopes. A leading system turn is
    /// emitted only for the MessageInArray placement; Bedrock wraps content in a
    /// `[{text}]` block.
    private static func flatMessageArray(
        userPrompt: String,
        system: String?,
        wireShape: String,
        config: ProviderSpec
    ) -> [JSONValue] {
        let bedrock = wireShape == "ChatBedrock"
        var messages: [JSONValue] = []

        if config.systemPlacement == "MessageInArray", let system, !system.isEmpty {
            messages.append(.object([
                ("role", .string(mapRole("system", config))),
                ("content", .string(system)),
            ]))
        }

        let content: JSONValue = bedrock
            ? .array([.object([("text", .string(userPrompt))])])
            : .string(userPrompt)
        messages.append(.object([
            ("role", .string(mapRole("user", config))),
            ("content", content),
        ]))
        return messages
    }

    private static func transformGoogleParts(
        body: inout [(String, JSONValue)],
        userPrompt: String,
        config: ProviderSpec
    ) {
        let contents: [JSONValue] = [
            .object([
                ("role", .string(mapRole("user", config))),
                ("parts", .array([.object([("text", .string(userPrompt))])])),
            ]),
        ]
        JSONObject.set(&body, "contents", .array(contents))
    }

    /// Translate a canonical role to the provider's wire role (identity when the
    /// provider declares no mapping).
    static func mapRole(_ role: String, _ config: ProviderSpec) -> String {
        config.roleMappings[role] ?? role
    }
}
