//


import Foundation

///
public struct AudioData: Sendable, Equatable {
    ///
    public var mimeType: String

    ///
    public var bytes: [UInt8]
}

///
public struct BatchHandle: Sendable, Equatable {
    ///
    public var id: String

    ///
    public var provider: ProviderName

    ///
    public var raw: Bool
}

///
public struct File: Sendable, Equatable {
    ///
    public var id: String

    ///
    public var uri: String

    ///
    public var mimeType: String

    ///
    public var name: String
}

///
public struct ImageData: Sendable, Equatable {
    ///
    public var mimeType: String

    ///
    public var bytes: [UInt8]
}

///
public struct ImageResponse: Sendable, Equatable {
    ///
    public var images: [ImageData]

    ///
    public var text: String

    ///
    public var usage: Usage

    ///
    public var finishReason: String

    ///
    public var finishMessage: String

    ///
    public var raw: JSONValue?
}

///
public struct LiveResult: Sendable, Equatable {
    ///
    public var models: [ModelInfo]

    ///
    public var errors: [String: ProviderError]
}

///
public struct MediaRef: Sendable, Equatable {
    ///
    public var mimeType: String

    ///
    public var bytes: [UInt8]
}

///
public struct Message: Sendable, Equatable {
    ///
    public var role: String

    ///
    public var content: String

    ///
    public var toolCalls: [ToolCall]

    ///
    public var toolResult: ToolResult?
}

///
public struct ModelInfo: Sendable, Equatable {
    ///
    public var id: String

    ///
    public var provider: ProviderName

    ///
    public var capabilities: [Capability]

    ///
    public var displayName: String

    ///
    public var description: String

    ///
    public var contextWindow: Int

    ///
    public var maxOutput: Int

    ///
    public var created: Int

    ///
    public var raw: JSONValue?
}

///
public struct MusicResponse: Sendable, Equatable {
    ///
    public var audio: [AudioData]

    ///
    public var text: String

    ///
    public var usage: Usage

    ///
    public var finishReason: String

    ///
    public var finishMessage: String

    ///
    public var raw: JSONValue?
}

///
public struct ProviderError: Sendable, Equatable {
    ///
    public var kind: String

    ///
    public var message: String
}

///
public struct Response: Sendable, Equatable {
    ///
    public var text: String

    ///
    public var usage: Usage

    ///
    public var finishReason: String

    ///
    public var finishMessage: String

    ///
    public var raw: JSONValue?
}

///
public struct SpeechResponse: Sendable, Equatable {
    ///
    public var audio: AudioData

    ///
    public var usage: Usage

    ///
    public var finishReason: String
}

///
public struct ToolCall: Sendable, Equatable {
    ///
    public var id: String

    ///
    public var name: String

    ///
    public var input: JSONValue?
}

///
public struct ToolResult: Sendable, Equatable {
    ///
    public var toolUseId: String

    ///
    public var content: String
}

///
public struct TranscriptSegment: Sendable, Equatable {
    ///
    public var text: String

    ///
    public var start: Int

    ///
    public var end: Int

    ///
    public var speaker: String
}

///
public struct TranscriptionHandle: Sendable, Equatable {
    ///
    public var id: String

    ///
    public var provider: ProviderName
}

///
public struct TranscriptionResponse: Sendable, Equatable {
    ///
    public var text: String

    ///
    public var segments: [TranscriptSegment]

    ///
    public var usage: Usage
}

///
public struct VideoData: Sendable, Equatable {
    ///
    public var mimeType: String

    ///
    public var url: String

    ///
    public var bytes: [UInt8]

    ///
    public var durationSeconds: Int
}

///
public struct VideoHandle: Sendable, Equatable {
    ///
    public var id: String

    ///
    public var provider: ProviderName

    ///
    public var raw: Bool

    ///
    public var model: String
}

///
public struct VideoResponse: Sendable, Equatable {
    ///
    public var videos: [VideoData]

    ///
    public var usage: Usage

    ///
    public var finishReason: String

    ///
    public var finishMessage: String

    ///
    public var raw: JSONValue?
}
