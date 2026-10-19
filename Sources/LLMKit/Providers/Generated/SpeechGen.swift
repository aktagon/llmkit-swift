// Code generated — DO NOT EDIT.


public struct SpeechModelDef: Sendable, Equatable {
    public let modelId: String
    public let label: String
    public let outputMime: String
    /// ADR-037 advisory fact (queryable, never gated); 0 when unverified.
    public let sampleRateHz: Int
    /// Speakers the model takes (1 or 2); nil = unknown, which sends (decision 009).
    public let maxSpeakers: Int?
    /// Whether the provider accepts a style; nil = unknown, only false blocks (decision 009).
    public let supportsSpeechStyle: Bool?
}

public struct SpeechGenDef: Sendable, Equatable {
    public let wireShape: String
    /// audioResponseEncoding: "base64Envelope" | "rawBody" | "base64InteractionSteps" | "hexEnvelope" (ADR-051).
    public let audioResponseEncoding: String
    public let genEndpoint: String
    public let models: [SpeechModelDef]
    /// Speech API base when it differs from the chat base; "" = use chat base.
    public let baseURL: String
    /// llmkit's body for this config can carry a style; false rejects every style (HANDOFF-099).
    public let carriesSpeechStyle: Bool
    /// The config has a multi-speaker body; false rejects every speaker request (HANDOFF-099).
    public let multiSpeaker: Bool
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
                    modelId: "gemini-3.1-flash-tts-preview",
                    label: "Gemini 3.1 Flash TTS Preview",
                    outputMime: "audio/l16",
                    sampleRateHz: 0,
                    maxSpeakers: nil,
                    supportsSpeechStyle: nil
                ),
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
            ],
            baseURL: "",
            carriesSpeechStyle: true,
            multiSpeaker: true
        )
    case .grok:
        return SpeechGenDef(
            wireShape: "SpeechXAI",
            audioResponseEncoding: "rawBody",
            genEndpoint: "/v1/tts",
            models: [
                SpeechModelDef(
                    modelId: "grok-tts",
                    label: "Grok TTS",
                    outputMime: "audio/mpeg",
                    sampleRateHz: 24000,
                    maxSpeakers: nil,
                    supportsSpeechStyle: true
                ),
            ],
            baseURL: "",
            carriesSpeechStyle: false,
            multiSpeaker: false
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
                    maxSpeakers: nil,
                    supportsSpeechStyle: false
                ),
                SpeechModelDef(
                    modelId: "inworld-tts-1.5-mini",
                    label: "Inworld TTS 1.5 Mini",
                    outputMime: "audio/wav",
                    sampleRateHz: 0,
                    maxSpeakers: nil,
                    supportsSpeechStyle: false
                ),
                SpeechModelDef(
                    modelId: "inworld-tts-2",
                    label: "Inworld TTS 2",
                    outputMime: "audio/wav",
                    sampleRateHz: 0,
                    maxSpeakers: nil,
                    supportsSpeechStyle: true
                ),
            ],
            baseURL: "",
            carriesSpeechStyle: false,
            multiSpeaker: false
        )
    case .minimax:
        return SpeechGenDef(
            wireShape: "SpeechMiniMax",
            audioResponseEncoding: "hexEnvelope",
            genEndpoint: "/v1/t2a_v2",
            models: [
                SpeechModelDef(
                    modelId: "speech-2.6-hd",
                    label: "MiniMax Speech 2.6 HD",
                    outputMime: "audio/mpeg",
                    sampleRateHz: 0,
                    maxSpeakers: nil,
                    supportsSpeechStyle: true
                ),
                SpeechModelDef(
                    modelId: "speech-2.6-turbo",
                    label: "MiniMax Speech 2.6 Turbo",
                    outputMime: "audio/mpeg",
                    sampleRateHz: 0,
                    maxSpeakers: nil,
                    supportsSpeechStyle: true
                ),
                SpeechModelDef(
                    modelId: "speech-2.8-hd",
                    label: "MiniMax Speech 2.8 HD",
                    outputMime: "audio/mpeg",
                    sampleRateHz: 0,
                    maxSpeakers: nil,
                    supportsSpeechStyle: true
                ),
                SpeechModelDef(
                    modelId: "speech-2.8-turbo",
                    label: "MiniMax Speech 2.8 Turbo",
                    outputMime: "audio/mpeg",
                    sampleRateHz: 0,
                    maxSpeakers: nil,
                    supportsSpeechStyle: true
                ),
            ],
            baseURL: "https://api.minimax.io",
            carriesSpeechStyle: false,
            multiSpeaker: false
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
                    maxSpeakers: nil,
                    supportsSpeechStyle: true
                ),
                SpeechModelDef(
                    modelId: "tts-1",
                    label: "TTS 1",
                    outputMime: "audio/mpeg",
                    sampleRateHz: 0,
                    maxSpeakers: nil,
                    supportsSpeechStyle: false
                ),
                SpeechModelDef(
                    modelId: "tts-1-hd",
                    label: "TTS 1 HD",
                    outputMime: "audio/mpeg",
                    sampleRateHz: 0,
                    maxSpeakers: nil,
                    supportsSpeechStyle: false
                ),
            ],
            baseURL: "",
            carriesSpeechStyle: true,
            multiSpeaker: false
        )
    case .openrouter:
        return SpeechGenDef(
            wireShape: "SpeechOpenAI",
            audioResponseEncoding: "rawBody",
            genEndpoint: "/v1/audio/speech",
            models: [
                SpeechModelDef(
                    modelId: "elevenlabs/eleven-v3",
                    label: "Eleven v3",
                    outputMime: "audio/mpeg",
                    sampleRateHz: 0,
                    maxSpeakers: 1,
                    supportsSpeechStyle: false
                ),
                SpeechModelDef(
                    modelId: "elevenlabs/eleven-v4",
                    label: "Eleven v4",
                    outputMime: "audio/mpeg",
                    sampleRateHz: 0,
                    maxSpeakers: 1,
                    supportsSpeechStyle: false
                ),
                SpeechModelDef(
                    modelId: "elevenlabs/eleven-v4-turbo",
                    label: "Eleven v4 Turbo",
                    outputMime: "audio/mpeg",
                    sampleRateHz: 0,
                    maxSpeakers: 1,
                    supportsSpeechStyle: false
                ),
                SpeechModelDef(
                    modelId: "fish-audio/drama-3",
                    label: "Fish Audio Drama 3",
                    outputMime: "audio/mpeg",
                    sampleRateHz: 0,
                    maxSpeakers: nil,
                    supportsSpeechStyle: true
                ),
                SpeechModelDef(
                    modelId: "fish-audio/s2.1-pro",
                    label: "Fish Audio S2.1 Pro",
                    outputMime: "audio/mpeg",
                    sampleRateHz: 0,
                    maxSpeakers: nil,
                    supportsSpeechStyle: true
                ),
                SpeechModelDef(
                    modelId: "google/gemini-3.1-flash-tts-preview",
                    label: "Gemini 3.1 Flash TTS Preview",
                    outputMime: "audio/mpeg",
                    sampleRateHz: 0,
                    maxSpeakers: nil,
                    supportsSpeechStyle: true
                ),
                SpeechModelDef(
                    modelId: "google/gemini-3.8-flash-lite-tts",
                    label: "Gemini 3.8 Flash Lite TTS",
                    outputMime: "audio/mpeg",
                    sampleRateHz: 0,
                    maxSpeakers: nil,
                    supportsSpeechStyle: true
                ),
                SpeechModelDef(
                    modelId: "google/gemini-3.8-flash-tts",
                    label: "Gemini 3.8 Flash TTS",
                    outputMime: "audio/mpeg",
                    sampleRateHz: 0,
                    maxSpeakers: nil,
                    supportsSpeechStyle: true
                ),
                SpeechModelDef(
                    modelId: "hexgrad/kokoro-82m",
                    label: "Kokoro 82M",
                    outputMime: "audio/mpeg",
                    sampleRateHz: 0,
                    maxSpeakers: 1,
                    supportsSpeechStyle: false
                ),
                SpeechModelDef(
                    modelId: "x-ai/grok-voice-tts-1.0",
                    label: "Grok Voice TTS 1.0",
                    outputMime: "audio/mpeg",
                    sampleRateHz: 0,
                    maxSpeakers: 1,
                    supportsSpeechStyle: false
                ),
            ],
            baseURL: "",
            carriesSpeechStyle: false,
            multiSpeaker: false
        )
    default: return nil
    }
}
