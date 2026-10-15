// Code generated — DO NOT EDIT.


public struct SpeechModelDef: Sendable, Equatable {
    public let modelId: String
    public let label: String
    public let outputMime: String
    /// ADR-037 advisory fact (queryable, never gated); 0 when unverified.
    public let sampleRateHz: Int
    /// Speakers a multi-speaker request declares; 0 = one voice only (BUG-091).
    public let maxSpeakers: Int
    /// Whether a style (style, addStyledLine) is sent to this model (BUG-091).
    public let supportsSpeechStyle: Bool
}

public struct SpeechGenDef: Sendable, Equatable {
    public let wireShape: String
    /// audioResponseEncoding: "base64Envelope" | "rawBody" | "base64InteractionSteps" (ADR-051).
    public let audioResponseEncoding: String
    public let genEndpoint: String
    public let models: [SpeechModelDef]
}

public func speechGenConfig(_ provider: ProviderName) -> SpeechGenDef? {
    switch provider {
    case .google:
        return SpeechGenDef(
            wireShape: "SpeechGemini",
            audioResponseEncoding: "base64InteractionSteps",
            genEndpoint: "/v1beta/interactions",
            models: [
                SpeechModelDef(
                    modelId: "gemini-3.8-flash-lite-tts",
                    label: "Gemini 3.8 Flash-Lite TTS",
                    outputMime: "audio/wav",
                    sampleRateHz: 24000,
                    maxSpeakers: 2,
                    supportsSpeechStyle: true
                ),
                SpeechModelDef(
                    modelId: "gemini-3.8-flash-tts",
                    label: "Gemini 3.8 Flash TTS",
                    outputMime: "audio/wav",
                    sampleRateHz: 24000,
                    maxSpeakers: 2,
                    supportsSpeechStyle: true
                ),
            ]
        )
    case .inworld:
        return SpeechGenDef(
            wireShape: "SpeechInworld",
            audioResponseEncoding: "base64Envelope",
            genEndpoint: "/tts/v1/voice",
            models: [
                SpeechModelDef(
                    modelId: "inworld-tts-1.5-max",
                    label: "Inworld TTS 1.5 Max",
                    outputMime: "audio/wav",
                    sampleRateHz: 0,
                    maxSpeakers: 0,
                    supportsSpeechStyle: false
                ),
                SpeechModelDef(
                    modelId: "inworld-tts-1.5-mini",
                    label: "Inworld TTS 1.5 Mini",
                    outputMime: "audio/wav",
                    sampleRateHz: 0,
                    maxSpeakers: 0,
                    supportsSpeechStyle: false
                ),
                SpeechModelDef(
                    modelId: "inworld-tts-2",
                    label: "Inworld TTS 2",
                    outputMime: "audio/wav",
                    sampleRateHz: 0,
                    maxSpeakers: 0,
                    supportsSpeechStyle: false
                ),
            ]
        )
    case .openai:
        return SpeechGenDef(
            wireShape: "SpeechOpenAI",
            audioResponseEncoding: "rawBody",
            genEndpoint: "/v1/audio/speech",
            models: [
                SpeechModelDef(
                    modelId: "gpt-4o-mini-tts",
                    label: "GPT-4o mini TTS",
                    outputMime: "audio/mpeg",
                    sampleRateHz: 0,
                    maxSpeakers: 0,
                    supportsSpeechStyle: true
                ),
                SpeechModelDef(
                    modelId: "tts-1",
                    label: "TTS 1",
                    outputMime: "audio/mpeg",
                    sampleRateHz: 0,
                    maxSpeakers: 0,
                    supportsSpeechStyle: false
                ),
                SpeechModelDef(
                    modelId: "tts-1-hd",
                    label: "TTS 1 HD",
                    outputMime: "audio/mpeg",
                    sampleRateHz: 0,
                    maxSpeakers: 0,
                    supportsSpeechStyle: false
                ),
            ]
        )
    default: return nil
    }
}
