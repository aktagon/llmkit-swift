import Foundation

/// A vision-input image attached to a text-generation request (ADR-060). The
/// builder's `.image(mime, data)` lowers into this carrier as a base64 data URI;
/// the transform emits it as the provider's native image block. Mirror of Rust's
/// `InputImage`.
struct InputImage: Sendable, Equatable {
    var url: String
    var mimeType: String
    var detail: String
}

/// A reference to an uploaded file attached to a text-generation request
/// (ADR-060). `id` addresses an OpenAI/Anthropic uploaded file; `uri`/`mimeType`
/// address a Google `file_data`. Mirror of the fields Rust's `File` carries.
struct FileRef: Sendable, Equatable {
    var id: String
    var uri: String
    var mimeType: String
}

/// Request-body message + tool transforms, selected by the effective
/// `chatWireShape` (ADR-047 / ADR-055 discriminator) and the generated
/// `ToolCallDef`, NOT by provider name — a file-by-file port of Rust's
/// `transforms.rs`. Covers the multi-turn message array (text, media, tool-call,
/// and tool-result turns) for the four chat wire shapes plus tool-definition
/// serialization.
enum Transforms {
    /// The internal message representation: a sum that is *exactly one of* text,
    /// media (text + image/file parts), tool-calls, or tool-result (ADR-026
    /// PIPE-007). The public surface is a flat product that could encode an
    /// illegal multi-carrier combination; this enum cannot, so the transforms
    /// dispatch with an exhaustive switch.
    enum Msg: Sendable {
        case text(role: String, text: String)
        case media(role: String, text: String, images: [InputImage], files: [FileRef])
        case calls([ToolCall])
        case result(ToolResult)
    }

    /// True when any turn carries a file reference — drives the Anthropic
    /// files-api beta header (BUG-017).
    static func hasFileParts(_ msgs: [Msg]) -> Bool {
        msgs.contains { if case let .media(_, _, _, files) = $0 { return !files.isEmpty }; return false }
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
            case let .media(role, text, images, files):
                let content: JSONValue = bedrock
                    ? .array(bedrockContentParts(images: images, text: text))
                    : .array(flatContentParts(images: images, files: files, text: text, wireShape: wireShape))
                messages.append(.object([
                    ("role", .string(mapRole(role, config))),
                    ("content", content),
                ]))
            }
        }
        return messages
    }

    /// The flat (OpenAI / Anthropic / Responses) content-parts array for a media
    /// turn: files first, then images, then the text — the fixed order the wire
    /// goldens pin. Anthropic uses `document`/`image` blocks with a `source`;
    /// OpenAI uses `file`/`image_url` blocks. Mirror of Rust's
    /// `build_flat_content_parts`.
    private static func flatContentParts(
        images: [InputImage], files: [FileRef], text: String, wireShape: String
    ) -> [JSONValue] {
        let isAnthropic = wireShape == "ChatAnthropic"
        var parts: [JSONValue] = []

        for file in files {
            if isAnthropic {
                parts.append(.object([
                    ("type", .string("document")),
                    ("source", .object([("type", .string("file")), ("file_id", .string(file.id))])),
                ]))
            } else {
                parts.append(.object([
                    ("type", .string("file")),
                    ("file", .object([("file_id", .string(file.id))])),
                ]))
            }
        }

        for image in images {
            if isAnthropic {
                if image.url.hasPrefix("data:") {
                    let (mime, data) = parseDataURI(image.url)
                    parts.append(.object([
                        ("type", .string("image")),
                        ("source", .object([
                            ("type", .string("base64")),
                            ("media_type", .string(mime)),
                            ("data", .string(data)),
                        ])),
                    ]))
                } else {
                    parts.append(.object([
                        ("type", .string("image")),
                        ("source", .object([("type", .string("url")), ("url", .string(image.url))])),
                    ]))
                }
            } else {
                let detail = image.detail.isEmpty ? "auto" : image.detail
                parts.append(.object([
                    ("type", .string("image_url")),
                    ("image_url", .object([("url", .string(image.url)), ("detail", .string(detail))])),
                ]))
            }
        }

        parts.append(.object([("type", .string("text")), ("text", .string(text))]))
        return parts
    }

    /// The Google `parts` array for a media turn: `file_data` for files,
    /// `inline_data` for data-URI images, then the text. Mirror of Rust's
    /// `build_google_parts`.
    private static func googleParts(images: [InputImage], files: [FileRef], text: String) -> [JSONValue] {
        var parts: [JSONValue] = []
        for file in files {
            parts.append(.object([("file_data", .object([
                ("file_uri", .string(file.uri)),
                ("mime_type", .string(file.mimeType)),
            ]))]))
        }
        for image in images where image.url.hasPrefix("data:") {
            let (mime, data) = parseDataURI(image.url)
            parts.append(.object([("inline_data", .object([
                ("mime_type", .string(mime)),
                ("data", .string(data)),
            ]))]))
        }
        parts.append(.object([("text", .string(text))]))
        return parts
    }

    /// The Bedrock Converse content array for a media turn: `image` blocks (files
    /// are unsupported here), then the text. Mirror of Rust's
    /// `build_bedrock_content_parts`.
    private static func bedrockContentParts(images: [InputImage], text: String) -> [JSONValue] {
        var parts: [JSONValue] = []
        for image in images {
            var (mime, data) = parseDataURI(image.url)
            if mime.isEmpty { mime = image.mimeType }
            parts.append(.object([("image", .object([
                ("format", .string(bedrockImageFormat(mime))),
                ("source", .object([("bytes", .string(data))])),
            ]))]))
        }
        parts.append(.object([("text", .string(text))]))
        return parts
    }

    /// Split a `data:<mime>;base64,<data>` URI into its mime type and payload.
    /// A non-data URI returns ("", url).
    private static func parseDataURI(_ url: String) -> (mime: String, data: String) {
        guard url.hasPrefix("data:"), let comma = url.firstIndex(of: ",") else { return ("", url) }
        let header = url[url.index(url.startIndex, offsetBy: 5)..<comma] // after "data:"
        let mime = header.split(separator: ";").first.map(String.init) ?? ""
        return (mime, String(url[url.index(after: comma)...]))
    }

    /// Derive the Converse `format` token from a MIME type (image/png -> "png").
    private static func bedrockImageFormat(_ mime: String) -> String {
        if let slash = mime.lastIndex(of: "/") { return String(mime[mime.index(after: slash)...]) }
        return mime
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
            case let .media(role, text, images, files):
                contents.append(.object([
                    ("role", .string(mapRole(role, config))),
                    ("parts", .array(googleParts(images: images, files: files, text: text))),
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
