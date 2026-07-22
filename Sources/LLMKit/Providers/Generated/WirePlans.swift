// Code generated — DO NOT EDIT.


//
//
//
//
//
//
//

public struct FieldBinding: Sendable, Equatable {
    public let path: String
    public let source: String
    public let optionKey: String
    public let constJson: String
    public let defaultJson: String
    public let transform: String
    public let omitIfEmpty: Bool
}

///
public struct BodyPlan: Sendable, Equatable {
    public let label: String
    public let bindings: [FieldBinding]
}

public let planVideoBedrock = BodyPlan(
    label: "video-bedrock",
    bindings: [
        FieldBinding(path: "modelId", source: "Model", optionKey: "", constJson: "", defaultJson: "", transform: "None", omitIfEmpty: false),
        FieldBinding(path: "modelInput.taskType", source: "Const", optionKey: "", constJson: "\"TEXT_VIDEO\"", defaultJson: "", transform: "None", omitIfEmpty: false),
        FieldBinding(path: "modelInput.textToVideoParams.text", source: "Prompt", optionKey: "", constJson: "", defaultJson: "", transform: "None", omitIfEmpty: false),
        FieldBinding(path: "outputDataConfig.s3OutputDataConfig.s3Uri", source: "Option", optionKey: "output_uri", constJson: "", defaultJson: "", transform: "None", omitIfEmpty: false),
    ]
)

public let planVideoGrok = BodyPlan(
    label: "video-grok",
    bindings: [
        FieldBinding(path: "model", source: "Model", optionKey: "", constJson: "", defaultJson: "", transform: "None", omitIfEmpty: false),
        FieldBinding(path: "prompt", source: "Prompt", optionKey: "", constJson: "", defaultJson: "", transform: "None", omitIfEmpty: false),
        FieldBinding(path: "image.url", source: "MediaRef", optionKey: "", constJson: "", defaultJson: "", transform: "DataUri", omitIfEmpty: true),
    ]
)

public let planVideoModelPrompt = BodyPlan(
    label: "video-model-prompt",
    bindings: [
        FieldBinding(path: "model", source: "Model", optionKey: "", constJson: "", defaultJson: "", transform: "None", omitIfEmpty: false),
        FieldBinding(path: "prompt", source: "Prompt", optionKey: "", constJson: "", defaultJson: "", transform: "None", omitIfEmpty: false),
    ]
)

public let planVideoPixVerse = BodyPlan(
    label: "video-pixverse",
    bindings: [
        FieldBinding(path: "model", source: "Model", optionKey: "", constJson: "", defaultJson: "", transform: "None", omitIfEmpty: false),
        FieldBinding(path: "prompt", source: "Prompt", optionKey: "", constJson: "", defaultJson: "", transform: "None", omitIfEmpty: false),
        FieldBinding(path: "duration", source: "Option", optionKey: "duration", constJson: "", defaultJson: "5", transform: "None", omitIfEmpty: false),
        FieldBinding(path: "quality", source: "Option", optionKey: "quality", constJson: "", defaultJson: "\"540p\"", transform: "None", omitIfEmpty: false),
        FieldBinding(path: "aspect_ratio", source: "Option", optionKey: "aspect_ratio", constJson: "", defaultJson: "\"16:9\"", transform: "None", omitIfEmpty: false),
    ]
)

public let planVideoQwen = BodyPlan(
    label: "video-qwen",
    bindings: [
        FieldBinding(path: "input.prompt", source: "Prompt", optionKey: "", constJson: "", defaultJson: "", transform: "None", omitIfEmpty: false),
        FieldBinding(path: "model", source: "Model", optionKey: "", constJson: "", defaultJson: "", transform: "None", omitIfEmpty: false),
    ]
)

public let planVideoVeoInstances = BodyPlan(
    label: "video-veo-instances",
    bindings: [
        FieldBinding(path: "instances[0].prompt", source: "Prompt", optionKey: "", constJson: "", defaultJson: "", transform: "None", omitIfEmpty: false),
    ]
)

///
public let videoBodyPlans: [String: BodyPlan] = [
    "VideoBedrock": planVideoBedrock,
    "VideoGrok": planVideoGrok,
    "VideoMinimax": planVideoModelPrompt,
    "VideoPixVerse": planVideoPixVerse,
    "VideoQwen": planVideoQwen,
    "VideoTogether": planVideoModelPrompt,
    "VideoVeo": planVideoVeoInstances,
    "VideoVertexVeo": planVideoVeoInstances,
    "VideoVidu": planVideoModelPrompt,
    "VideoZhipu": planVideoModelPrompt,
]
