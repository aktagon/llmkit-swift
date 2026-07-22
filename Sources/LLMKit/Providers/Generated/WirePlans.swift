// Code generated — DO NOT EDIT.


// Body plans (ADR-073 T1 config-data interpreter — VIDEO PROVING CUT).
//
// Emitted as DATA: each plan is an ordered list of field bindings a
// handwritten interpreter (slice 3) walks to build a video submit body. No
// runtime reads these tables yet. The vocabulary is CLOSED (INT-001): five
// sources (Model | Prompt | Option | Const | MediaRef), two transforms
// (None | DataUri).

public struct FieldBinding: Sendable, Equatable {
    public let path: String
    public let source: String
    public let optionKey: String
    public let constJson: String
    public let defaultJson: String
    public let transform: String
    public let omitIfEmpty: Bool
}

/// A named, reusable request-body plan; several wire shapes may share one.
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

/// Maps a video wire shape to its body plan (ADR-073).
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
