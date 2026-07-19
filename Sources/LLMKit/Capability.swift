import Foundation

///
///
///
///
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
