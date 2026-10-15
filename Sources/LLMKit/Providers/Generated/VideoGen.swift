// Code generated — DO NOT EDIT.


public struct VideoModelDef: Sendable, Equatable {
    public let modelId: String
    public let label: String
    public let supportsImageToVideo: Bool
    public let maxDurationSeconds: Int
    public let outputMime: String
    public let resolutions: [String]
    /// 0 = no llmkit limit, the provider decides volume (BUG-011).
    public let maxInputImages: Int
}

public struct VideoGenDef: Sendable, Equatable {
    public let wireShape: String
    /// One of download | url | output-uri.
    public let outputDelivery: String
    /// Video API base when it differs from the chat base; "" = use chat base.
    public let videoBaseURL: String
    /// Submit requests per carried input, TextOnly first; each endpoint is
    /// relative to the resolved video base (ADR-096).
    public let variants: [RequestVariant]
    /// Poll template with an {id} placeholder.
    public let pollEndpoint: String
    /// File-retrieve template with {file_id} for two-hop providers; "" = single-hop.
    public let fileEndpoint: String
    public let submitHandleField: String
    public let requiresOutputURI: Bool
    public let models: [VideoModelDef]
}

public func videoGenConfig(_ provider: ProviderName) -> VideoGenDef? {
    switch provider {
    case .bedrock:
        return VideoGenDef(
            wireShape: "VideoBedrock",
            outputDelivery: "DeliveryOutputURI",
            videoBaseURL: "",
            variants: [
                RequestVariant(carries: "TextOnly", shape: "", endpoint: "/async-invoke"),
            ],
            pollEndpoint: "/async-invoke/{id}",
            fileEndpoint: "",
            submitHandleField: "invocationArn",
            requiresOutputURI: true,
            models: [
                VideoModelDef(
                    modelId: "amazon.nova-reel-v1:0",
                    label: "Nova Reel",
                    supportsImageToVideo: false,
                    maxDurationSeconds: 6,
                    outputMime: "video/mp4",
                    resolutions: ["720p"],
                    maxInputImages: 0
                ),
            ]
        )
    case .google:
        return VideoGenDef(
            wireShape: "VideoVeo",
            outputDelivery: "DeliveryDownload",
            videoBaseURL: "",
            variants: [
                RequestVariant(carries: "TextOnly", shape: "", endpoint: "/v1beta/models/{model}:predictLongRunning"),
                RequestVariant(carries: "WithSeedFrame", shape: "", endpoint: "/v1beta/models/{model}:predictLongRunning"),
            ],
            pollEndpoint: "/v1beta/{id}",
            fileEndpoint: "",
            submitHandleField: "name",
            requiresOutputURI: false,
            models: [
                VideoModelDef(
                    modelId: "veo-3.1-fast-generate-preview",
                    label: "Veo 3.1 Fast",
                    supportsImageToVideo: true,
                    maxDurationSeconds: 8,
                    outputMime: "video/mp4",
                    resolutions: ["1080p", "4k", "720p"],
                    maxInputImages: 1
                ),
                VideoModelDef(
                    modelId: "veo-3.1-generate-preview",
                    label: "Veo 3.1",
                    supportsImageToVideo: true,
                    maxDurationSeconds: 8,
                    outputMime: "video/mp4",
                    resolutions: ["1080p", "720p"],
                    maxInputImages: 1
                ),
                VideoModelDef(
                    modelId: "veo-3.1-lite-generate-preview",
                    label: "Veo 3.1 Lite",
                    supportsImageToVideo: true,
                    maxDurationSeconds: 8,
                    outputMime: "video/mp4",
                    resolutions: ["1080p", "720p"],
                    maxInputImages: 1
                ),
            ]
        )
    case .grok:
        return VideoGenDef(
            wireShape: "VideoGrok",
            outputDelivery: "DeliveryURL",
            videoBaseURL: "",
            variants: [
                RequestVariant(carries: "TextOnly", shape: "", endpoint: "/v1/videos/generations"),
                RequestVariant(carries: "WithSeedFrame", shape: "", endpoint: "/v1/videos/generations"),
            ],
            pollEndpoint: "/v1/videos/{id}",
            fileEndpoint: "",
            submitHandleField: "request_id",
            requiresOutputURI: false,
            models: [
                VideoModelDef(
                    modelId: "grok-imagine-video",
                    label: "Grok Imagine Video",
                    supportsImageToVideo: true,
                    maxDurationSeconds: 15,
                    outputMime: "video/mp4",
                    resolutions: ["480p", "720p"],
                    maxInputImages: 1
                ),
            ]
        )
    case .minimax:
        return VideoGenDef(
            wireShape: "VideoMinimax",
            outputDelivery: "DeliveryURL",
            videoBaseURL: "https://api.minimax.io",
            variants: [
                RequestVariant(carries: "TextOnly", shape: "", endpoint: "/v1/video_generation"),
            ],
            pollEndpoint: "/v1/query/video_generation?task_id={id}",
            fileEndpoint: "/v1/files/retrieve?file_id={file_id}",
            submitHandleField: "task_id",
            requiresOutputURI: false,
            models: [
                VideoModelDef(
                    modelId: "MiniMax-Hailuo-2.3",
                    label: "MiniMax Hailuo 2.3",
                    supportsImageToVideo: false,
                    maxDurationSeconds: 6,
                    outputMime: "video/mp4",
                    resolutions: ["1080p", "768p"],
                    maxInputImages: 0
                ),
            ]
        )
    case .pixverse:
        return VideoGenDef(
            wireShape: "VideoPixVerse",
            outputDelivery: "DeliveryURL",
            videoBaseURL: "",
            variants: [
                RequestVariant(carries: "TextOnly", shape: "", endpoint: "/openapi/v2/video/text/generate"),
            ],
            pollEndpoint: "/openapi/v2/video/result/{id}",
            fileEndpoint: "",
            submitHandleField: "Resp.video_id",
            requiresOutputURI: false,
            models: [
                VideoModelDef(
                    modelId: "v4.5",
                    label: "PixVerse v4.5",
                    supportsImageToVideo: false,
                    maxDurationSeconds: 8,
                    outputMime: "video/mp4",
                    resolutions: [],
                    maxInputImages: 0
                ),
                VideoModelDef(
                    modelId: "v5",
                    label: "PixVerse v5",
                    supportsImageToVideo: false,
                    maxDurationSeconds: 8,
                    outputMime: "video/mp4",
                    resolutions: [],
                    maxInputImages: 0
                ),
                VideoModelDef(
                    modelId: "v6",
                    label: "PixVerse v6",
                    supportsImageToVideo: false,
                    maxDurationSeconds: 15,
                    outputMime: "video/mp4",
                    resolutions: [],
                    maxInputImages: 0
                ),
            ]
        )
    case .qwen:
        return VideoGenDef(
            wireShape: "VideoQwen",
            outputDelivery: "DeliveryURL",
            videoBaseURL: "https://dashscope-intl.aliyuncs.com",
            variants: [
                RequestVariant(carries: "TextOnly", shape: "", endpoint: "/api/v1/services/aigc/video-generation/video-synthesis"),
            ],
            pollEndpoint: "/api/v1/tasks/{id}",
            fileEndpoint: "",
            submitHandleField: "output.task_id",
            requiresOutputURI: false,
            models: [
                VideoModelDef(
                    modelId: "wan2.2-t2v-plus",
                    label: "Wan 2.2 T2V Plus",
                    supportsImageToVideo: false,
                    maxDurationSeconds: 5,
                    outputMime: "video/mp4",
                    resolutions: ["720p"],
                    maxInputImages: 0
                ),
            ]
        )
    case .together:
        return VideoGenDef(
            wireShape: "VideoTogether",
            outputDelivery: "DeliveryURL",
            videoBaseURL: "",
            variants: [
                RequestVariant(carries: "TextOnly", shape: "", endpoint: "/v2/videos"),
            ],
            pollEndpoint: "/v2/videos/{id}",
            fileEndpoint: "",
            submitHandleField: "id",
            requiresOutputURI: false,
            models: [
                VideoModelDef(
                    modelId: "minimax/video-01-director",
                    label: "MiniMax Video 01 Director (Together)",
                    supportsImageToVideo: false,
                    maxDurationSeconds: 6,
                    outputMime: "video/mp4",
                    resolutions: ["720p"],
                    maxInputImages: 0
                ),
            ]
        )
    case .vertex:
        return VideoGenDef(
            wireShape: "VideoVertexVeo",
            outputDelivery: "DeliveryDownload",
            videoBaseURL: "",
            variants: [
                RequestVariant(carries: "TextOnly", shape: "", endpoint: "/{model}:predictLongRunning"),
                RequestVariant(carries: "WithSeedFrame", shape: "", endpoint: "/{model}:predictLongRunning"),
            ],
            pollEndpoint: "/{model}:fetchPredictOperation",
            fileEndpoint: "",
            submitHandleField: "name",
            requiresOutputURI: false,
            models: [
                VideoModelDef(
                    modelId: "veo-3.1-fast-generate-001",
                    label: "Veo 3.1 Fast",
                    supportsImageToVideo: true,
                    maxDurationSeconds: 8,
                    outputMime: "video/mp4",
                    resolutions: ["1080p", "720p"],
                    maxInputImages: 1
                ),
                VideoModelDef(
                    modelId: "veo-3.1-generate-001",
                    label: "Veo 3.1",
                    supportsImageToVideo: true,
                    maxDurationSeconds: 8,
                    outputMime: "video/mp4",
                    resolutions: ["1080p", "4k", "720p"],
                    maxInputImages: 1
                ),
                VideoModelDef(
                    modelId: "veo-3.1-generate-preview",
                    label: "Veo 3.1",
                    supportsImageToVideo: true,
                    maxDurationSeconds: 8,
                    outputMime: "video/mp4",
                    resolutions: ["1080p", "720p"],
                    maxInputImages: 1
                ),
                VideoModelDef(
                    modelId: "veo-3.1-lite-generate-001",
                    label: "Veo 3.1 Lite",
                    supportsImageToVideo: false,
                    maxDurationSeconds: 8,
                    outputMime: "video/mp4",
                    resolutions: ["1080p", "720p"],
                    maxInputImages: 0
                ),
            ]
        )
    case .vidu:
        return VideoGenDef(
            wireShape: "VideoVidu",
            outputDelivery: "DeliveryURL",
            videoBaseURL: "",
            variants: [
                RequestVariant(carries: "TextOnly", shape: "", endpoint: "/ent/v2/text2video"),
            ],
            pollEndpoint: "/ent/v2/tasks/{id}/creations",
            fileEndpoint: "",
            submitHandleField: "task_id",
            requiresOutputURI: false,
            models: [
                VideoModelDef(
                    modelId: "viduq1",
                    label: "Vidu Q1",
                    supportsImageToVideo: false,
                    maxDurationSeconds: 16,
                    outputMime: "video/mp4",
                    resolutions: [],
                    maxInputImages: 0
                ),
                VideoModelDef(
                    modelId: "viduq2",
                    label: "Vidu Q2",
                    supportsImageToVideo: false,
                    maxDurationSeconds: 16,
                    outputMime: "video/mp4",
                    resolutions: [],
                    maxInputImages: 0
                ),
                VideoModelDef(
                    modelId: "viduq3-pro",
                    label: "Vidu Q3 Pro",
                    supportsImageToVideo: false,
                    maxDurationSeconds: 16,
                    outputMime: "video/mp4",
                    resolutions: [],
                    maxInputImages: 0
                ),
            ]
        )
    case .zhipu:
        return VideoGenDef(
            wireShape: "VideoZhipu",
            outputDelivery: "DeliveryURL",
            videoBaseURL: "",
            variants: [
                RequestVariant(carries: "TextOnly", shape: "", endpoint: "/v4/videos/generations"),
            ],
            pollEndpoint: "/v4/async-result/{id}",
            fileEndpoint: "",
            submitHandleField: "id",
            requiresOutputURI: false,
            models: [
                VideoModelDef(
                    modelId: "cogvideox-3",
                    label: "CogVideoX-3",
                    supportsImageToVideo: false,
                    maxDurationSeconds: 10,
                    outputMime: "video/mp4",
                    resolutions: ["1080p", "4k", "720p"],
                    maxInputImages: 0
                ),
            ]
        )
    default: return nil
    }
}
