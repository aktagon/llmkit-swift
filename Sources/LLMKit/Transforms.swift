import Foundation

///
///
///
///
///
///
enum Transforms {
    ///
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

    ///
    ///
    ///
    ///
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

    ///
    ///
    static func mapRole(_ role: String, _ config: ProviderSpec) -> String {
        config.roleMappings[role] ?? role
    }
}
