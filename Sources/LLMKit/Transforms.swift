import Foundation

///
///
///
///
enum Transforms {
    ///
    ///
    ///
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

    ///
    ///
    static func mapRole(_ role: String, _ config: ProviderSpec) -> String {
        config.roleMappings[role] ?? role
    }
}
