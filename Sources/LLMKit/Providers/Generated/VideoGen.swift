// Code generated — DO NOT EDIT.


public struct VideoModelDef: Sendable, Equatable {
    public let modelId: String
    public let label: String
    public let supportsImageToVideo: Bool
    /// Whether lastFrame and addReferenceImage are accepted; false means the
    /// request is rejected before send (BUG-089).
    public let supportsLastFrame: Bool
    public let supportsReferenceImages: Bool
    public let maxDurationSeconds: Int
    public let outputMime: String
    public let resolutions: [String]
    /// Accepted aspect ratios (e.g. "16:9"); empty = no fixed set.
    public let aspectRatios: [String]
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
    /// Cancel template with {model} and {operation_id}; "" = no documented cancel.
    public let cancelEndpoint: String
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
                RequestVariant(carries: ["TextOnly"], shape: "", endpoint: "/async-invoke"),
            ],
            pollEndpoint: "/async-invoke/{id}",
            fileEndpoint: "",
            cancelEndpoint: "",
            submitHandleField: "invocationArn",
            requiresOutputURI: true,
            models: [
                VideoModelDef(
                    modelId: "amazon.nova-reel-v1:0",
                    label: "Nova Reel",
                    supportsImageToVideo: false,
                    supportsLastFrame: false,
                    supportsReferenceImages: false,
                    maxDurationSeconds: 6,
                    outputMime: "video/mp4",
                    resolutions: ["720p"],
                    aspectRatios: [],
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
                RequestVariant(carries: ["TextOnly"], shape: "", endpoint: "/v1beta/models/{model}:predictLongRunning"),
                RequestVariant(carries: ["WithReferenceImages"], shape: "", endpoint: "/v1beta/models/{model}:predictLongRunning"),
                RequestVariant(carries: ["WithSeedFrame"], shape: "", endpoint: "/v1beta/models/{model}:predictLongRunning"),
                RequestVariant(carries: ["WithSeedFrame", "WithLastFrame"], shape: "", endpoint: "/v1beta/models/{model}:predictLongRunning"),
            ],
            pollEndpoint: "/v1beta/{id}",
            fileEndpoint: "",
            cancelEndpoint: "",
            submitHandleField: "name",
            requiresOutputURI: false,
            models: [
                VideoModelDef(
                    modelId: "veo-3.1-fast-generate-preview",
                    label: "Veo 3.1 Fast",
                    supportsImageToVideo: true,
                    supportsLastFrame: true,
                    supportsReferenceImages: true,
                    maxDurationSeconds: 8,
                    outputMime: "video/mp4",
                    resolutions: ["1080p", "4k", "720p"],
                    aspectRatios: ["16:9", "9:16"],
                    maxInputImages: 1
                ),
                VideoModelDef(
                    modelId: "veo-3.1-generate-preview",
                    label: "Veo 3.1",
                    supportsImageToVideo: true,
                    supportsLastFrame: true,
                    supportsReferenceImages: true,
                    maxDurationSeconds: 8,
                    outputMime: "video/mp4",
                    resolutions: ["1080p", "720p"],
                    aspectRatios: ["16:9", "9:16"],
                    maxInputImages: 1
                ),
                VideoModelDef(
                    modelId: "veo-3.1-lite-generate-preview",
                    label: "Veo 3.1 Lite",
                    supportsImageToVideo: true,
                    supportsLastFrame: true,
                    supportsReferenceImages: false,
                    maxDurationSeconds: 8,
                    outputMime: "video/mp4",
                    resolutions: ["1080p", "720p"],
                    aspectRatios: ["16:9", "9:16"],
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
                RequestVariant(carries: ["TextOnly"], shape: "", endpoint: "/v1/videos/generations"),
                RequestVariant(carries: ["WithSeedFrame"], shape: "", endpoint: "/v1/videos/generations"),
            ],
            pollEndpoint: "/v1/videos/{id}",
            fileEndpoint: "",
            cancelEndpoint: "",
            submitHandleField: "request_id",
            requiresOutputURI: false,
            models: [
                VideoModelDef(
                    modelId: "grok-imagine-video",
                    label: "Grok Imagine Video",
                    supportsImageToVideo: true,
                    supportsLastFrame: false,
                    supportsReferenceImages: false,
                    maxDurationSeconds: 15,
                    outputMime: "video/mp4",
                    resolutions: ["480p", "720p"],
                    aspectRatios: ["16:9", "1:1", "21:9", "2:3", "3:2", "3:4", "4:3", "5:2", "9:16"],
                    maxInputImages: 1
                ),
                VideoModelDef(
                    modelId: "grok-imagine-video-1.5",
                    label: "Grok Imagine Video 1.5",
                    supportsImageToVideo: true,
                    supportsLastFrame: false,
                    supportsReferenceImages: false,
                    maxDurationSeconds: 15,
                    outputMime: "video/mp4",
                    resolutions: ["1080p", "480p", "720p"],
                    aspectRatios: ["16:9", "1:1", "21:9", "2:3", "3:2", "3:4", "4:3", "5:2", "9:16"],
                    maxInputImages: 1
                ),
                VideoModelDef(
                    modelId: "grok-imagine-video-1.5-lite",
                    label: "Grok Imagine Video 1.5 Lite",
                    supportsImageToVideo: true,
                    supportsLastFrame: false,
                    supportsReferenceImages: false,
                    maxDurationSeconds: 15,
                    outputMime: "video/mp4",
                    resolutions: ["1080p", "480p", "720p"],
                    aspectRatios: ["16:9", "1:1", "21:9", "2:3", "3:2", "3:4", "4:3", "5:2", "9:16"],
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
                RequestVariant(carries: ["TextOnly"], shape: "", endpoint: "/v1/video_generation"),
            ],
            pollEndpoint: "/v1/query/video_generation?task_id={id}",
            fileEndpoint: "/v1/files/retrieve?file_id={file_id}",
            cancelEndpoint: "",
            submitHandleField: "task_id",
            requiresOutputURI: false,
            models: [
                VideoModelDef(
                    modelId: "MiniMax-Hailuo-2.3",
                    label: "MiniMax Hailuo 2.3",
                    supportsImageToVideo: false,
                    supportsLastFrame: false,
                    supportsReferenceImages: false,
                    maxDurationSeconds: 6,
                    outputMime: "video/mp4",
                    resolutions: ["1080p", "768p"],
                    aspectRatios: [],
                    maxInputImages: 0
                ),
            ]
        )
    case .openrouter:
        return VideoGenDef(
            wireShape: "VideoOpenRouter",
            outputDelivery: "DeliveryDownload",
            videoBaseURL: "",
            variants: [
                RequestVariant(carries: ["TextOnly"], shape: "", endpoint: "/v1/videos"),
                RequestVariant(carries: ["WithSeedFrame"], shape: "", endpoint: "/v1/videos"),
                RequestVariant(carries: ["WithSeedFrame", "WithLastFrame"], shape: "", endpoint: "/v1/videos"),
            ],
            pollEndpoint: "/v1/videos/{id}",
            fileEndpoint: "",
            cancelEndpoint: "",
            submitHandleField: "id",
            requiresOutputURI: false,
            models: [
                VideoModelDef(
                    modelId: "alibaba/wan-3.0",
                    label: "Wan 3.0",
                    supportsImageToVideo: true,
                    supportsLastFrame: true,
                    supportsReferenceImages: false,
                    maxDurationSeconds: 30,
                    outputMime: "video/mp4",
                    resolutions: ["1080p", "480p", "720p"],
                    aspectRatios: ["16:9", "1:1", "3:4", "4:3", "9:16"],
                    maxInputImages: 0
                ),
                VideoModelDef(
                    modelId: "bytedance/seedance-2.0",
                    label: "Seedance 2.0",
                    supportsImageToVideo: true,
                    supportsLastFrame: true,
                    supportsReferenceImages: false,
                    maxDurationSeconds: 15,
                    outputMime: "video/mp4",
                    resolutions: ["1080p", "480p", "4K", "720p"],
                    aspectRatios: ["16:9", "1:1", "21:9", "3:4", "4:3", "9:16", "9:21"],
                    maxInputImages: 0
                ),
                VideoModelDef(
                    modelId: "bytedance/seedance-2.0-fast",
                    label: "Seedance 2.0 Fast",
                    supportsImageToVideo: true,
                    supportsLastFrame: true,
                    supportsReferenceImages: false,
                    maxDurationSeconds: 15,
                    outputMime: "video/mp4",
                    resolutions: ["480p", "720p"],
                    aspectRatios: ["16:9", "1:1", "21:9", "3:4", "4:3", "9:16", "9:21"],
                    maxInputImages: 0
                ),
                VideoModelDef(
                    modelId: "bytedance/seedance-2.5",
                    label: "Seedance 2.5",
                    supportsImageToVideo: true,
                    supportsLastFrame: true,
                    supportsReferenceImages: false,
                    maxDurationSeconds: 30,
                    outputMime: "video/mp4",
                    resolutions: ["480p", "720p"],
                    aspectRatios: ["16:9", "1:1", "21:9", "3:4", "4:3", "9:16"],
                    maxInputImages: 0
                ),
                VideoModelDef(
                    modelId: "google/veo-3.1-fast",
                    label: "Veo 3.1 Fast",
                    supportsImageToVideo: true,
                    supportsLastFrame: true,
                    supportsReferenceImages: false,
                    maxDurationSeconds: 8,
                    outputMime: "video/mp4",
                    resolutions: ["1080p", "4K", "720p"],
                    aspectRatios: ["16:9", "9:16"],
                    maxInputImages: 0
                ),
                VideoModelDef(
                    modelId: "google/veo-3.1-lite",
                    label: "Veo 3.1 Lite",
                    supportsImageToVideo: true,
                    supportsLastFrame: true,
                    supportsReferenceImages: false,
                    maxDurationSeconds: 8,
                    outputMime: "video/mp4",
                    resolutions: ["1080p", "720p"],
                    aspectRatios: ["16:9", "9:16"],
                    maxInputImages: 0
                ),
                VideoModelDef(
                    modelId: "heygen/heygen-video-1",
                    label: "HeyGen Video 1",
                    supportsImageToVideo: true,
                    supportsLastFrame: false,
                    supportsReferenceImages: false,
                    maxDurationSeconds: 15,
                    outputMime: "video/mp4",
                    resolutions: ["2K", "480p", "768p"],
                    aspectRatios: ["16:9", "1:1", "21:9", "3:4", "4:3", "9:16"],
                    maxInputImages: 0
                ),
                VideoModelDef(
                    modelId: "kwaivgi/kling-v3.0-std",
                    label: "Kling 3.0 Standard",
                    supportsImageToVideo: true,
                    supportsLastFrame: true,
                    supportsReferenceImages: false,
                    maxDurationSeconds: 15,
                    outputMime: "video/mp4",
                    resolutions: ["720p"],
                    aspectRatios: ["16:9", "1:1", "9:16"],
                    maxInputImages: 0
                ),
                VideoModelDef(
                    modelId: "minimax/hailuo-3",
                    label: "Hailuo 3",
                    supportsImageToVideo: true,
                    supportsLastFrame: true,
                    supportsReferenceImages: false,
                    maxDurationSeconds: 15,
                    outputMime: "video/mp4",
                    resolutions: ["2K"],
                    aspectRatios: ["16:9", "1:1", "21:9", "3:4", "4:3", "9:16"],
                    maxInputImages: 0
                ),
                VideoModelDef(
                    modelId: "x-ai/grok-imagine-video-1.5-lite",
                    label: "Grok Imagine Video 1.5 Lite",
                    supportsImageToVideo: true,
                    supportsLastFrame: false,
                    supportsReferenceImages: false,
                    maxDurationSeconds: 15,
                    outputMime: "video/mp4",
                    resolutions: ["1080p", "480p", "720p"],
                    aspectRatios: ["16:9", "1:1", "2:3", "3:2", "3:4", "4:3", "9:16"],
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
                RequestVariant(carries: ["TextOnly"], shape: "", endpoint: "/openapi/v2/video/text/generate"),
            ],
            pollEndpoint: "/openapi/v2/video/result/{id}",
            fileEndpoint: "",
            cancelEndpoint: "",
            submitHandleField: "Resp.video_id",
            requiresOutputURI: false,
            models: [
                VideoModelDef(
                    modelId: "v4.5",
                    label: "PixVerse v4.5",
                    supportsImageToVideo: false,
                    supportsLastFrame: false,
                    supportsReferenceImages: false,
                    maxDurationSeconds: 8,
                    outputMime: "video/mp4",
                    resolutions: [],
                    aspectRatios: [],
                    maxInputImages: 0
                ),
                VideoModelDef(
                    modelId: "v5",
                    label: "PixVerse v5",
                    supportsImageToVideo: false,
                    supportsLastFrame: false,
                    supportsReferenceImages: false,
                    maxDurationSeconds: 8,
                    outputMime: "video/mp4",
                    resolutions: [],
                    aspectRatios: [],
                    maxInputImages: 0
                ),
                VideoModelDef(
                    modelId: "v6",
                    label: "PixVerse v6",
                    supportsImageToVideo: false,
                    supportsLastFrame: false,
                    supportsReferenceImages: false,
                    maxDurationSeconds: 15,
                    outputMime: "video/mp4",
                    resolutions: [],
                    aspectRatios: [],
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
                RequestVariant(carries: ["TextOnly"], shape: "", endpoint: "/api/v1/services/aigc/video-generation/video-synthesis"),
            ],
            pollEndpoint: "/api/v1/tasks/{id}",
            fileEndpoint: "",
            cancelEndpoint: "",
            submitHandleField: "output.task_id",
            requiresOutputURI: false,
            models: [
                VideoModelDef(
                    modelId: "wan2.2-t2v-plus",
                    label: "Wan 2.2 T2V Plus",
                    supportsImageToVideo: false,
                    supportsLastFrame: false,
                    supportsReferenceImages: false,
                    maxDurationSeconds: 5,
                    outputMime: "video/mp4",
                    resolutions: ["720p"],
                    aspectRatios: [],
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
                RequestVariant(carries: ["TextOnly"], shape: "", endpoint: "/v2/videos"),
            ],
            pollEndpoint: "/v2/videos/{id}",
            fileEndpoint: "",
            cancelEndpoint: "",
            submitHandleField: "id",
            requiresOutputURI: false,
            models: [
                VideoModelDef(
                    modelId: "minimax/video-01-director",
                    label: "MiniMax Video 01 Director (Together)",
                    supportsImageToVideo: false,
                    supportsLastFrame: false,
                    supportsReferenceImages: false,
                    maxDurationSeconds: 6,
                    outputMime: "video/mp4",
                    resolutions: ["720p"],
                    aspectRatios: [],
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
                RequestVariant(carries: ["TextOnly"], shape: "", endpoint: "/{model}:predictLongRunning"),
                RequestVariant(carries: ["WithReferenceImages"], shape: "", endpoint: "/{model}:predictLongRunning"),
                RequestVariant(carries: ["WithSeedFrame"], shape: "", endpoint: "/{model}:predictLongRunning"),
                RequestVariant(carries: ["WithSeedFrame", "WithLastFrame"], shape: "", endpoint: "/{model}:predictLongRunning"),
            ],
            pollEndpoint: "/{model}:fetchPredictOperation",
            fileEndpoint: "",
            cancelEndpoint: "/{model}/operations/{operation_id}:cancel",
            submitHandleField: "name",
            requiresOutputURI: false,
            models: [
                VideoModelDef(
                    modelId: "veo-3.1-fast-generate-001",
                    label: "Veo 3.1 Fast",
                    supportsImageToVideo: true,
                    supportsLastFrame: true,
                    supportsReferenceImages: true,
                    maxDurationSeconds: 8,
                    outputMime: "video/mp4",
                    resolutions: ["1080p", "720p"],
                    aspectRatios: ["16:9", "9:16"],
                    maxInputImages: 1
                ),
                VideoModelDef(
                    modelId: "veo-3.1-generate-001",
                    label: "Veo 3.1",
                    supportsImageToVideo: true,
                    supportsLastFrame: true,
                    supportsReferenceImages: true,
                    maxDurationSeconds: 8,
                    outputMime: "video/mp4",
                    resolutions: ["1080p", "4k", "720p"],
                    aspectRatios: ["16:9", "9:16"],
                    maxInputImages: 1
                ),
                VideoModelDef(
                    modelId: "veo-3.1-generate-preview",
                    label: "Veo 3.1",
                    supportsImageToVideo: true,
                    supportsLastFrame: false,
                    supportsReferenceImages: true,
                    maxDurationSeconds: 8,
                    outputMime: "video/mp4",
                    resolutions: ["1080p", "720p"],
                    aspectRatios: ["16:9", "9:16"],
                    maxInputImages: 1
                ),
                VideoModelDef(
                    modelId: "veo-3.1-lite-generate-001",
                    label: "Veo 3.1 Lite",
                    supportsImageToVideo: false,
                    supportsLastFrame: false,
                    supportsReferenceImages: false,
                    maxDurationSeconds: 8,
                    outputMime: "video/mp4",
                    resolutions: ["1080p", "720p"],
                    aspectRatios: ["16:9", "9:16"],
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
                RequestVariant(carries: ["TextOnly"], shape: "", endpoint: "/ent/v2/text2video"),
            ],
            pollEndpoint: "/ent/v2/tasks/{id}/creations",
            fileEndpoint: "",
            cancelEndpoint: "",
            submitHandleField: "task_id",
            requiresOutputURI: false,
            models: [
                VideoModelDef(
                    modelId: "viduq1",
                    label: "Vidu Q1",
                    supportsImageToVideo: false,
                    supportsLastFrame: false,
                    supportsReferenceImages: false,
                    maxDurationSeconds: 16,
                    outputMime: "video/mp4",
                    resolutions: [],
                    aspectRatios: [],
                    maxInputImages: 0
                ),
                VideoModelDef(
                    modelId: "viduq2",
                    label: "Vidu Q2",
                    supportsImageToVideo: false,
                    supportsLastFrame: false,
                    supportsReferenceImages: false,
                    maxDurationSeconds: 16,
                    outputMime: "video/mp4",
                    resolutions: [],
                    aspectRatios: [],
                    maxInputImages: 0
                ),
                VideoModelDef(
                    modelId: "viduq3-pro",
                    label: "Vidu Q3 Pro",
                    supportsImageToVideo: false,
                    supportsLastFrame: false,
                    supportsReferenceImages: false,
                    maxDurationSeconds: 16,
                    outputMime: "video/mp4",
                    resolutions: [],
                    aspectRatios: [],
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
                RequestVariant(carries: ["TextOnly"], shape: "", endpoint: "/v4/videos/generations"),
            ],
            pollEndpoint: "/v4/async-result/{id}",
            fileEndpoint: "",
            cancelEndpoint: "",
            submitHandleField: "id",
            requiresOutputURI: false,
            models: [
                VideoModelDef(
                    modelId: "cogvideox-3",
                    label: "CogVideoX-3",
                    supportsImageToVideo: false,
                    supportsLastFrame: false,
                    supportsReferenceImages: false,
                    maxDurationSeconds: 10,
                    outputMime: "video/mp4",
                    resolutions: ["1080p", "4k", "720p"],
                    aspectRatios: [],
                    maxInputImages: 0
                ),
            ]
        )
    default: return nil
    }
}
