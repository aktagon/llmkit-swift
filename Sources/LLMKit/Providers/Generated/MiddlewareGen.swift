//


///
public enum MiddlewarePhase: Sendable, Equatable {
    case pre
    case post
}

///
///
public enum MiddlewareOp: String, Sendable, Equatable {
    case llmRequest = "llm_request"
    case toolCall = "tool_call"
    case cacheCreate = "cache_create"
    case upload = "upload"
    case batchSubmit = "batch_submit"
    case imageGeneration = "image_generation"
    case musicGeneration = "music_generation"
    case videoGeneration = "video_generation"
    case modelsList = "models_list"
}
