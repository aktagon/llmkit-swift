// Code generated — DO NOT EDIT.


/// The inputs a request variant carries (ADR-096).
public enum CarriedInput {
    public static let textOnly = "TextOnly"
    public static let withReferenceImages = "WithReferenceImages"
}

/// Image request shapes: each names one request body (ADR-096).
public enum ImageRequestShape {
    public static let inlineParts = "InlineParts"
    public static let jsonGenerationsOpenAI = "JSONGenerationsOpenAI"
    public static let multipartForm = "MultipartForm"
    public static let jsonInlineRefs = "JSONInlineRefs"
    /// Deprecated: no provider accepts this since 2026-10-15 (Vertex Imagen shut down, BUG-101); removed at the next major.
    public static let jsonPredict = "JSONPredict"
    public static let jsonGenerations = "JSONGenerations"
}

/// One wire request of an image or video config, keyed by the inputs it
/// carries (ADR-096). `shape` is empty on a video variant; an empty
/// `endpoint` means the provider's main endpoint template.
public struct RequestVariant: Sendable, Equatable {
    public let carries: String
    public let shape: String
    public let endpoint: String
}

public struct ImageModelDef: Sendable, Equatable {
    public let modelId: String
    public let label: String
    public let aspectRatios: [String]
    public let imageSizes: [String]
    /// Images llmkit serializes when the wire shape fixes the count
    /// (e.g. Grok's single-seed slot); 0 = no llmkit limit (BUG-011).
    public let maxInputImages: Int
    /// Whether llmkit sends Image Parts for this model; false means the
    /// runtime rejects them (BUG-096).
    public let supportsImageInput: Bool
}

public struct ImageGenDef: Sendable, Equatable {
    public let outputMode: String
    /// Response wire family selecting the response parser (BUG-024).
    public let responseShape: String
    public let usageInputPath: String
    public let usageOutputPath: String
    public let usageReasoningPath: String
    /// One request per carried input, TextOnly first (ADR-096).
    public let variants: [RequestVariant]
    public let models: [ImageModelDef]
}

public func imageGenConfig(_ provider: ProviderName) -> ImageGenDef? {
    switch provider {
    case .google:
        return ImageGenDef(
            outputMode: "Base64Inline",
            responseShape: "GoogleParts",
            usageInputPath: "usageMetadata.promptTokenCount",
            usageOutputPath: "usageMetadata.candidatesTokenCount",
            usageReasoningPath: "usageMetadata.thoughtsTokenCount",
            variants: [
                RequestVariant(carries: "TextOnly", shape: "InlineParts", endpoint: ""),
                RequestVariant(carries: "WithReferenceImages", shape: "InlineParts", endpoint: ""),
            ],
            models: [
                ImageModelDef(
                    modelId: "gemini-3-pro-image-preview",
                    label: "Nano Banana Pro",
                    aspectRatios: ["16:9", "1:1", "21:9", "2:3", "3:2", "3:4", "4:3", "4:5", "5:4", "9:16"],
                    imageSizes: ["1K", "2K", "4K"],
                    maxInputImages: 0,
                    supportsImageInput: true
                ),
                ImageModelDef(
                    modelId: "gemini-3.1-flash-image-preview",
                    label: "Nano Banana 2",
                    aspectRatios: ["16:9", "1:1", "1:4", "1:8", "21:9", "2:3", "3:2", "3:4", "4:1", "4:3", "4:5", "5:4", "8:1", "9:16"],
                    imageSizes: ["1K", "2K", "4K", "512"],
                    maxInputImages: 0,
                    supportsImageInput: true
                ),
            ]
        )
    case .grok:
        return ImageGenDef(
            outputMode: "Base64Inline",
            responseShape: "DataArrayB64Json",
            usageInputPath: "",
            usageOutputPath: "",
            usageReasoningPath: "",
            variants: [
                RequestVariant(carries: "TextOnly", shape: "JSONInlineRefs", endpoint: "/v1/images/generations"),
                RequestVariant(carries: "WithReferenceImages", shape: "JSONInlineRefs", endpoint: "/v1/images/edits"),
            ],
            models: [
                ImageModelDef(
                    modelId: "grok-imagine-image-quality",
                    label: "Grok Imagine Quality",
                    aspectRatios: ["16:9", "19.5:9", "1:1", "1:2", "20:9", "2:1", "2:3", "3:2", "3:4", "4:3", "9:16", "9:19.5", "9:20", "auto"],
                    imageSizes: [],
                    maxInputImages: 0,
                    supportsImageInput: true
                ),
            ]
        )
    case .openai:
        return ImageGenDef(
            outputMode: "Base64Inline",
            responseShape: "DataArrayB64Json",
            usageInputPath: "usage.input_tokens",
            usageOutputPath: "usage.output_tokens",
            usageReasoningPath: "",
            variants: [
                RequestVariant(carries: "TextOnly", shape: "JSONGenerationsOpenAI", endpoint: "/v1/images/generations"),
                RequestVariant(carries: "WithReferenceImages", shape: "MultipartForm", endpoint: "/v1/images/edits"),
            ],
            models: [
                ImageModelDef(
                    modelId: "gpt-image-1",
                    label: "GPT Image 1",
                    aspectRatios: [],
                    imageSizes: [],
                    maxInputImages: 0,
                    supportsImageInput: true
                ),
                ImageModelDef(
                    modelId: "gpt-image-1-mini",
                    label: "GPT Image 1 Mini",
                    aspectRatios: [],
                    imageSizes: [],
                    maxInputImages: 0,
                    supportsImageInput: true
                ),
                ImageModelDef(
                    modelId: "gpt-image-1.5",
                    label: "GPT Image 1.5",
                    aspectRatios: [],
                    imageSizes: [],
                    maxInputImages: 0,
                    supportsImageInput: true
                ),
                ImageModelDef(
                    modelId: "gpt-image-2",
                    label: "GPT Image 2",
                    aspectRatios: [],
                    imageSizes: [],
                    maxInputImages: 0,
                    supportsImageInput: true
                ),
            ]
        )
    case .openrouter:
        return ImageGenDef(
            outputMode: "Base64Inline",
            responseShape: "DataArrayB64Json",
            usageInputPath: "usage.prompt_tokens",
            usageOutputPath: "usage.completion_tokens",
            usageReasoningPath: "",
            variants: [
                RequestVariant(carries: "TextOnly", shape: "JSONGenerations", endpoint: "/v1/images"),
            ],
            models: [
                ImageModelDef(
                    modelId: "google/gemini-2.5-flash-image",
                    label: "Nano Banana (Gemini 2.5 Flash Image)",
                    aspectRatios: [],
                    imageSizes: [],
                    maxInputImages: 0,
                    supportsImageInput: false
                ),
                ImageModelDef(
                    modelId: "google/gemini-3-pro-image",
                    label: "Nano Banana Pro (Gemini 3 Pro Image)",
                    aspectRatios: [],
                    imageSizes: [],
                    maxInputImages: 0,
                    supportsImageInput: false
                ),
                ImageModelDef(
                    modelId: "google/gemini-3.1-flash-image",
                    label: "Nano Banana 2 (Gemini 3.1 Flash Image)",
                    aspectRatios: [],
                    imageSizes: [],
                    maxInputImages: 0,
                    supportsImageInput: false
                ),
                ImageModelDef(
                    modelId: "google/gemini-3.1-flash-lite-image",
                    label: "Nano Banana 2 Lite (Gemini 3.1 Flash Lite Image)",
                    aspectRatios: [],
                    imageSizes: [],
                    maxInputImages: 0,
                    supportsImageInput: false
                ),
                ImageModelDef(
                    modelId: "openai/gpt-5-image",
                    label: "GPT-5 Image",
                    aspectRatios: [],
                    imageSizes: [],
                    maxInputImages: 0,
                    supportsImageInput: false
                ),
                ImageModelDef(
                    modelId: "openai/gpt-5-image-mini",
                    label: "GPT-5 Image Mini",
                    aspectRatios: [],
                    imageSizes: [],
                    maxInputImages: 0,
                    supportsImageInput: false
                ),
                ImageModelDef(
                    modelId: "openai/gpt-5.4-image-2",
                    label: "GPT-5.4 Image 2",
                    aspectRatios: [],
                    imageSizes: [],
                    maxInputImages: 0,
                    supportsImageInput: false
                ),
            ]
        )
    case .recraft:
        return ImageGenDef(
            outputMode: "Base64Inline",
            responseShape: "DataArrayB64Json",
            usageInputPath: "",
            usageOutputPath: "",
            usageReasoningPath: "",
            variants: [
                RequestVariant(carries: "TextOnly", shape: "JSONGenerations", endpoint: "/v1/images/generations"),
            ],
            models: [
                ImageModelDef(
                    modelId: "recraftv3",
                    label: "Recraft V3",
                    aspectRatios: [],
                    imageSizes: [],
                    maxInputImages: 0,
                    supportsImageInput: false
                ),
                ImageModelDef(
                    modelId: "recraftv3_vector",
                    label: "Recraft V3 (vector / SVG)",
                    aspectRatios: [],
                    imageSizes: [],
                    maxInputImages: 0,
                    supportsImageInput: false
                ),
            ]
        )
    default: return nil
    }
}
