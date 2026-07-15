import Foundation

/// Request-body message + tool transforms, selected by the effective
/// `chatWireShape` (ADR-047 / ADR-055 discriminator) and the generated
/// `ToolCallDef`, NOT by provider name — a file-by-file port of Rust's
/// `transforms.rs`. Covers the multi-turn message array (text, tool-call, and
/// tool-result turns) for the four chat wire shapes plus tool-definition
/// serialization. Media Parts remain deferred to a later phase.
enum Transforms {
    /// The internal message representation: a sum that is *exactly one of* text,
    /// tool-calls, or tool-result (ADR-026 PIPE-007). The public `Message` is a
    /// flat product that can encode an illegal multi-carrier combination; this
    /// enum cannot, so the transforms dispatch with an exhaustive switch.
    enum Msg: Sendable {
        case text(role: String, text: String)
        case calls([ToolCall])
        case result(ToolResult)
    }

    // MARK: - Message array

    /// Append the provider-specific message array to `body`, built from the
    /// internal message list + an optional system turn.
    static func applyMessageShape(
        body: inout [(String, JSONValue)],
        msgs: [Msg],
        system: String?,
        wireShape: String,
        config: ProviderSpec
    ) {
        if wireShape == "ChatGoogle" {
            JSONObject.set(&body, "contents", .array(googleContents(msgs: msgs, system: system, config: config)))
        } else if wireShape == "ChatResponsesOpenAI" {
            JSONObject.set(&body, "input", .array(flatMessageArray(msgs: msgs, system: system, wireShape: wireShape, config: config)))
        } else {
            JSONObject.set(&body, "messages", .array(flatMessageArray(msgs: msgs, system: system, wireShape: wireShape, config: config)))
        }
    }

    /// The shared flat message array used by both the Chat Completions
    /// ("messages") and Responses ("input") envelopes. A leading system turn is
    /// emitted only for the MessageInArray placement; Bedrock wraps text content
    /// in a `[{text}]` block.
    private static func flatMessageArray(
        msgs: [Msg],
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

        for msg in msgs {
            switch msg {
            case let .result(result):
                messages.append(toolResultMessage(config, result))
            case let .calls(calls):
                messages.append(toolCallMessage(config, calls))
            case let .text(role, text):
                let content: JSONValue = bedrock
                    ? .array([.object([("text", .string(text))])])
                    : .string(text)
                messages.append(.object([
                    ("role", .string(mapRole(role, config))),
                    ("content", content),
                ]))
            }
        }
        return messages
    }

    private static func googleContents(
        msgs: [Msg],
        system: String?,
        config: ProviderSpec
    ) -> [JSONValue] {
        // Google identifies a tool result by function NAME, but ToolResult
        // carries only tool_use_id. Recover id->name from the preceding call
        // turns (which always precede their result in a valid history).
        var idToName: [String: String] = [:]
        var contents: [JSONValue] = []
        for msg in msgs {
            switch msg {
            case let .result(result):
                let resolved = idToName[result.toolUseId].map {
                    ToolResult(toolUseId: $0, content: result.content)
                } ?? result
                contents.append(toolResultMessage(config, resolved))
            case let .calls(calls):
                for call in calls { idToName[call.id] = call.name }
                contents.append(toolCallMessage(config, calls))
            case let .text(role, text):
                contents.append(.object([
                    ("role", .string(mapRole(role, config))),
                    ("parts", .array([.object([("text", .string(text))])])),
                ]))
            }
        }
        return contents
    }

    // MARK: - Tool definitions

    /// Serialize the tool definitions into the provider-specific wire field,
    /// selected by `chatWireShape` + the generated `ToolCallDef.argsFormat`.
    static func applyToolDefs(
        _ body: inout [(String, JSONValue)],
        _ config: ProviderSpec,
        _ tools: [Tool]
    ) {
        if tools.isEmpty { return }
        if config.chatWireShape == "ChatBedrock" {
            bedrockToolDefs(&body, tools)
        } else if config.chatWireShape == "ChatGoogle" {
            let field = toolCallConfig(config.name).map(\.paramsWireField).flatMap { $0.isEmpty ? nil : $0 } ?? "parameters"
            googleFunctionDeclarations(&body, tools, field)
        } else if toolCallConfig(config.name)?.argsFormat == "map" {
            anthropicTools(&body, tools)
        } else {
            openaiFunctions(&body, tools)
        }
    }

    private static func openaiFunctions(_ body: inout [(String, JSONValue)], _ tools: [Tool]) {
        JSONObject.set(&body, "tools", .array(tools.map { tool in
            .object([
                ("type", .string("function")),
                ("function", .object([
                    ("name", .string(tool.name)),
                    ("description", .string(tool.description)),
                    ("parameters", tool.schema),
                ])),
            ])
        }))
    }

    private static func anthropicTools(_ body: inout [(String, JSONValue)], _ tools: [Tool]) {
        JSONObject.set(&body, "tools", .array(tools.map { tool in
            .object([
                ("name", .string(tool.name)),
                ("description", .string(tool.description)),
                ("input_schema", tool.schema),
            ])
        }))
    }

    private static func googleFunctionDeclarations(
        _ body: inout [(String, JSONValue)], _ tools: [Tool], _ paramsField: String
    ) {
        let decls: [JSONValue] = tools.map { tool in
            .object([
                ("name", .string(tool.name)),
                ("description", .string(tool.description)),
                (paramsField, tool.schema),
            ])
        }
        JSONObject.set(&body, "tools", .array([.object([("functionDeclarations", .array(decls))])]))
    }

    private static func bedrockToolDefs(_ body: inout [(String, JSONValue)], _ tools: [Tool]) {
        let defs: [JSONValue] = tools.map { tool in
            .object([("toolSpec", .object([
                ("name", .string(tool.name)),
                ("description", .string(tool.description)),
                ("inputSchema", .object([("json", tool.schema)])),
            ]))])
        }
        JSONObject.set(&body, "toolConfig", .object([("tools", .array(defs))]))
    }

    // MARK: - Tool-call / tool-result turn messages

    private static func toolCallInput(_ call: ToolCall) -> JSONValue {
        call.input ?? .object([])
    }

    static func toolCallMessage(_ config: ProviderSpec, _ calls: [ToolCall]) -> JSONValue {
        if config.chatWireShape == "ChatBedrock" {
            let content: [JSONValue] = calls.map { call in
                .object([("toolUse", .object([
                    ("toolUseId", .string(call.id)),
                    ("name", .string(call.name)),
                    ("input", toolCallInput(call)),
                ]))])
            }
            return .object([("role", .string(mapRole("assistant", config))), ("content", .array(content))])
        }
        if config.chatWireShape == "ChatGoogle" {
            let parts: [JSONValue] = calls.map { call in
                .object([("functionCall", .object([
                    ("name", .string(call.name)),
                    ("args", toolCallInput(call)),
                ]))])
            }
            return .object([("role", .string(mapRole("assistant", config))), ("parts", .array(parts))])
        }
        if toolCallConfig(config.name)?.argsFormat == "map" {
            let content: [JSONValue] = calls.map { call in
                .object([
                    ("type", .string("tool_use")),
                    ("id", .string(call.id)),
                    ("name", .string(call.name)),
                    ("input", toolCallInput(call)),
                ])
            }
            return .object([("role", .string(mapRole("assistant", config))), ("content", .array(content))])
        }
        let toolCalls: [JSONValue] = calls.map { call in
            .object([
                ("id", .string(call.id)),
                ("type", .string("function")),
                ("function", .object([
                    ("name", .string(call.name)),
                    ("arguments", .string(toolCallInput(call).serialized())),
                ])),
            ])
        }
        return .object([("role", .string(mapRole("assistant", config))), ("tool_calls", .array(toolCalls))])
    }

    static func toolResultMessage(_ config: ProviderSpec, _ result: ToolResult) -> JSONValue {
        if config.chatWireShape == "ChatBedrock" {
            return .object([("role", .string("user")), ("content", .array([
                .object([("toolResult", .object([
                    ("toolUseId", .string(result.toolUseId)),
                    ("content", .array([.object([("text", .string(result.content))])])),
                ]))]),
            ]))])
        }
        if config.chatWireShape == "ChatGoogle" {
            return .object([("role", .string("user")), ("parts", .array([
                .object([("functionResponse", .object([
                    ("name", .string(result.toolUseId)),
                    ("response", .object([("result", .string(result.content))])),
                ]))]),
            ]))])
        }
        if let tc = toolCallConfig(config.name), tc.resultRole == "user", tc.argsFormat == "map" {
            return .object([("role", .string("user")), ("content", .array([
                .object([
                    ("type", .string("tool_result")),
                    ("tool_use_id", .string(result.toolUseId)),
                    ("content", .string(result.content)),
                ]),
            ]))])
        }
        return .object([
            ("role", .string("tool")),
            ("content", .string(result.content)),
            ("tool_call_id", .string(result.toolUseId)),
        ])
    }

    // MARK: - Tool-call extraction (response side)

    /// Extract the tool calls the model issued in the raw response, selected by
    /// `chatWireShape` + `ToolCallDef.argsFormat`.
    static func extractToolCalls(_ raw: JSONValue, _ config: ProviderSpec) -> [ToolCall] {
        if config.chatWireShape == "ChatBedrock" {
            return extractBedrockToolCalls(raw)
        }
        if config.chatWireShape == "ChatGoogle" {
            return extractGoogleToolCalls(raw)
        }
        if toolCallConfig(config.name)?.argsFormat == "map" {
            return extractAnthropicToolCalls(raw)
        }
        return extractOpenAIToolCalls(raw, config)
    }

    private static func extractOpenAIToolCalls(_ raw: JSONValue, _ config: ProviderSpec) -> [ToolCall] {
        guard case let .array(calls)? = raw.lookup("choices[0].message.tool_calls") else { return [] }
        let argsFormat = toolCallConfig(config.name)?.argsFormat ?? "json_string"
        return calls.compactMap { call in
            guard let function = call.member("function"),
                  case let .string(name)? = function.member("name") else { return nil }
            let input: JSONValue
            if argsFormat == "json_string" {
                if case let .string(arguments)? = function.member("arguments"),
                   let parsed = try? JSONValue.parse(arguments), case .object = parsed {
                    input = parsed
                } else {
                    input = .object([])
                }
            } else if let object = function.member("arguments"), case .object = object {
                input = object
            } else {
                input = .object([])
            }
            return ToolCall(id: stringify(call.member("id")), name: name, input: input)
        }
    }

    private static func extractAnthropicToolCalls(_ raw: JSONValue) -> [ToolCall] {
        guard case let .array(blocks)? = raw.member("content") else { return [] }
        return blocks.compactMap { block in
            guard case .string("tool_use")? = block.member("type") else { return nil }
            return ToolCall(id: stringify(block.member("id")), name: stringify(block.member("name")), input: objectOrEmpty(block.member("input")))
        }
    }

    private static func extractGoogleToolCalls(_ raw: JSONValue) -> [ToolCall] {
        guard case let .array(parts)? = raw.lookup("candidates[0].content.parts") else { return [] }
        return parts.compactMap { part in
            guard let fc = part.member("functionCall") else { return nil }
            let name = stringify(fc.member("name"))
            return ToolCall(id: name, name: name, input: objectOrEmpty(fc.member("args")))
        }
    }

    private static func extractBedrockToolCalls(_ raw: JSONValue) -> [ToolCall] {
        guard case let .array(blocks)? = raw.lookup("output.message.content") else { return [] }
        return blocks.compactMap { block in
            guard let toolUse = block.member("toolUse") else { return nil }
            return ToolCall(id: stringify(toolUse.member("toolUseId")), name: stringify(toolUse.member("name")), input: objectOrEmpty(toolUse.member("input")))
        }
    }

    // MARK: - Helpers

    /// The value if it is an object, else an empty object — for a tool-call
    /// input that may be absent or non-object.
    private static func objectOrEmpty(_ value: JSONValue?) -> JSONValue {
        if let value, case .object = value { return value }
        return .object([])
    }

    /// Translate a canonical role to the provider's wire role (identity when the
    /// provider declares no mapping).
    static func mapRole(_ role: String, _ config: ProviderSpec) -> String {
        config.roleMappings[role] ?? role
    }

    private static func stringify(_ value: JSONValue?) -> String {
        switch value {
        case let .string(s): return s
        case let .int(i): return String(i)
        case let .double(d): return String(d)
        case let .bool(b): return String(b)
        default: return ""
        }
    }
}
