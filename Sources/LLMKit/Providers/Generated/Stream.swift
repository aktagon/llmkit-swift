//


struct StreamDef: Sendable, Equatable {
    let endpoint: String
    let param: String
    let paramValue: String
    let deltaTextPath: String
    let doneSignal: String
    let usesEventTypes: Bool
    let contentEvent: String
    let doneEvent: String
    let usageEvent: String
    let usageInputPath: String
    let usageOutputPath: String
    let usageOptIn: Bool
}

func streamConfig(_ provider: ProviderName) -> StreamDef? {
    switch provider {
    case .ai21:
        return StreamDef(
            endpoint: "",
            param: "stream",
            paramValue: "true",
            deltaTextPath: "choices[0].delta.content",
            doneSignal: "[DONE]",
            usesEventTypes: false,
            contentEvent: "",
            doneEvent: "",
            usageEvent: "",
            usageInputPath: "usage.prompt_tokens",
            usageOutputPath: "usage.completion_tokens",
            usageOptIn: false
        )
    case .anthropic:
        return StreamDef(
            endpoint: "",
            param: "stream",
            paramValue: "true",
            deltaTextPath: "delta.text",
            doneSignal: "message_stop",
            usesEventTypes: true,
            contentEvent: "content_block_delta",
            doneEvent: "message_stop",
            usageEvent: "message_delta",
            usageInputPath: "usage.input_tokens",
            usageOutputPath: "usage.output_tokens",
            usageOptIn: false
        )
    case .azure:
        return StreamDef(
            endpoint: "",
            param: "stream",
            paramValue: "true",
            deltaTextPath: "choices[0].delta.content",
            doneSignal: "[DONE]",
            usesEventTypes: false,
            contentEvent: "",
            doneEvent: "",
            usageEvent: "",
            usageInputPath: "usage.prompt_tokens",
            usageOutputPath: "usage.completion_tokens",
            usageOptIn: false
        )
    case .cerebras:
        return StreamDef(
            endpoint: "",
            param: "stream",
            paramValue: "true",
            deltaTextPath: "choices[0].delta.content",
            doneSignal: "[DONE]",
            usesEventTypes: false,
            contentEvent: "",
            doneEvent: "",
            usageEvent: "",
            usageInputPath: "usage.prompt_tokens",
            usageOutputPath: "usage.completion_tokens",
            usageOptIn: false
        )
    case .cohere:
        return StreamDef(
            endpoint: "",
            param: "stream",
            paramValue: "true",
            deltaTextPath: "choices[0].delta.content",
            doneSignal: "[DONE]",
            usesEventTypes: false,
            contentEvent: "",
            doneEvent: "",
            usageEvent: "",
            usageInputPath: "usage.prompt_tokens",
            usageOutputPath: "usage.completion_tokens",
            usageOptIn: false
        )
    case .deepseek:
        return StreamDef(
            endpoint: "",
            param: "stream",
            paramValue: "true",
            deltaTextPath: "choices[0].delta.content",
            doneSignal: "[DONE]",
            usesEventTypes: false,
            contentEvent: "",
            doneEvent: "",
            usageEvent: "",
            usageInputPath: "usage.prompt_tokens",
            usageOutputPath: "usage.completion_tokens",
            usageOptIn: false
        )
    case .doubao:
        return StreamDef(
            endpoint: "",
            param: "stream",
            paramValue: "true",
            deltaTextPath: "choices[0].delta.content",
            doneSignal: "[DONE]",
            usesEventTypes: false,
            contentEvent: "",
            doneEvent: "",
            usageEvent: "",
            usageInputPath: "usage.prompt_tokens",
            usageOutputPath: "usage.completion_tokens",
            usageOptIn: false
        )
    case .ernie:
        return StreamDef(
            endpoint: "",
            param: "stream",
            paramValue: "true",
            deltaTextPath: "choices[0].delta.content",
            doneSignal: "[DONE]",
            usesEventTypes: false,
            contentEvent: "",
            doneEvent: "",
            usageEvent: "",
            usageInputPath: "usage.prompt_tokens",
            usageOutputPath: "usage.completion_tokens",
            usageOptIn: false
        )
    case .fireworks:
        return StreamDef(
            endpoint: "",
            param: "stream",
            paramValue: "true",
            deltaTextPath: "choices[0].delta.content",
            doneSignal: "[DONE]",
            usesEventTypes: false,
            contentEvent: "",
            doneEvent: "",
            usageEvent: "",
            usageInputPath: "usage.prompt_tokens",
            usageOutputPath: "usage.completion_tokens",
            usageOptIn: false
        )
    case .google:
        return StreamDef(
            endpoint: "/v1beta/models/{model}:streamGenerateContent?alt=sse",
            param: "",
            paramValue: "",
            deltaTextPath: "candidates[0].content.parts[0].text",
            doneSignal: "",
            usesEventTypes: false,
            contentEvent: "",
            doneEvent: "",
            usageEvent: "",
            usageInputPath: "usageMetadata.promptTokenCount",
            usageOutputPath: "usageMetadata.candidatesTokenCount",
            usageOptIn: false
        )
    case .grok:
        return StreamDef(
            endpoint: "",
            param: "stream",
            paramValue: "true",
            deltaTextPath: "choices[0].delta.content",
            doneSignal: "[DONE]",
            usesEventTypes: false,
            contentEvent: "",
            doneEvent: "",
            usageEvent: "",
            usageInputPath: "usage.prompt_tokens",
            usageOutputPath: "usage.completion_tokens",
            usageOptIn: false
        )
    case .groq:
        return StreamDef(
            endpoint: "",
            param: "stream",
            paramValue: "true",
            deltaTextPath: "choices[0].delta.content",
            doneSignal: "[DONE]",
            usesEventTypes: false,
            contentEvent: "",
            doneEvent: "",
            usageEvent: "",
            usageInputPath: "usage.prompt_tokens",
            usageOutputPath: "usage.completion_tokens",
            usageOptIn: false
        )
    case .jan:
        return StreamDef(
            endpoint: "",
            param: "stream",
            paramValue: "true",
            deltaTextPath: "choices[0].delta.content",
            doneSignal: "[DONE]",
            usesEventTypes: false,
            contentEvent: "",
            doneEvent: "",
            usageEvent: "",
            usageInputPath: "usage.prompt_tokens",
            usageOutputPath: "usage.completion_tokens",
            usageOptIn: false
        )
    case .llamacpp:
        return StreamDef(
            endpoint: "",
            param: "stream",
            paramValue: "true",
            deltaTextPath: "choices[0].delta.content",
            doneSignal: "[DONE]",
            usesEventTypes: false,
            contentEvent: "",
            doneEvent: "",
            usageEvent: "",
            usageInputPath: "usage.prompt_tokens",
            usageOutputPath: "usage.completion_tokens",
            usageOptIn: false
        )
    case .lmstudio:
        return StreamDef(
            endpoint: "",
            param: "stream",
            paramValue: "true",
            deltaTextPath: "choices[0].delta.content",
            doneSignal: "[DONE]",
            usesEventTypes: false,
            contentEvent: "",
            doneEvent: "",
            usageEvent: "",
            usageInputPath: "usage.prompt_tokens",
            usageOutputPath: "usage.completion_tokens",
            usageOptIn: false
        )
    case .minimax:
        return StreamDef(
            endpoint: "",
            param: "stream",
            paramValue: "true",
            deltaTextPath: "choices[0].delta.content",
            doneSignal: "[DONE]",
            usesEventTypes: false,
            contentEvent: "",
            doneEvent: "",
            usageEvent: "",
            usageInputPath: "usage.prompt_tokens",
            usageOutputPath: "usage.completion_tokens",
            usageOptIn: false
        )
    case .mistral:
        return StreamDef(
            endpoint: "",
            param: "stream",
            paramValue: "true",
            deltaTextPath: "choices[0].delta.content",
            doneSignal: "[DONE]",
            usesEventTypes: false,
            contentEvent: "",
            doneEvent: "",
            usageEvent: "",
            usageInputPath: "usage.prompt_tokens",
            usageOutputPath: "usage.completion_tokens",
            usageOptIn: false
        )
    case .moonshot:
        return StreamDef(
            endpoint: "",
            param: "stream",
            paramValue: "true",
            deltaTextPath: "choices[0].delta.content",
            doneSignal: "[DONE]",
            usesEventTypes: false,
            contentEvent: "",
            doneEvent: "",
            usageEvent: "",
            usageInputPath: "usage.prompt_tokens",
            usageOutputPath: "usage.completion_tokens",
            usageOptIn: false
        )
    case .ollama:
        return StreamDef(
            endpoint: "",
            param: "stream",
            paramValue: "true",
            deltaTextPath: "choices[0].delta.content",
            doneSignal: "[DONE]",
            usesEventTypes: false,
            contentEvent: "",
            doneEvent: "",
            usageEvent: "",
            usageInputPath: "usage.prompt_tokens",
            usageOutputPath: "usage.completion_tokens",
            usageOptIn: false
        )
    case .openai:
        return StreamDef(
            endpoint: "",
            param: "stream",
            paramValue: "true",
            deltaTextPath: "choices[0].delta.content",
            doneSignal: "[DONE]",
            usesEventTypes: false,
            contentEvent: "",
            doneEvent: "",
            usageEvent: "",
            usageInputPath: "usage.prompt_tokens",
            usageOutputPath: "usage.completion_tokens",
            usageOptIn: true
        )
    case .openrouter:
        return StreamDef(
            endpoint: "",
            param: "stream",
            paramValue: "true",
            deltaTextPath: "choices[0].delta.content",
            doneSignal: "[DONE]",
            usesEventTypes: false,
            contentEvent: "",
            doneEvent: "",
            usageEvent: "",
            usageInputPath: "usage.prompt_tokens",
            usageOutputPath: "usage.completion_tokens",
            usageOptIn: false
        )
    case .perplexity:
        return StreamDef(
            endpoint: "",
            param: "stream",
            paramValue: "true",
            deltaTextPath: "choices[0].delta.content",
            doneSignal: "[DONE]",
            usesEventTypes: false,
            contentEvent: "",
            doneEvent: "",
            usageEvent: "",
            usageInputPath: "usage.prompt_tokens",
            usageOutputPath: "usage.completion_tokens",
            usageOptIn: false
        )
    case .qwen:
        return StreamDef(
            endpoint: "",
            param: "stream",
            paramValue: "true",
            deltaTextPath: "choices[0].delta.content",
            doneSignal: "[DONE]",
            usesEventTypes: false,
            contentEvent: "",
            doneEvent: "",
            usageEvent: "",
            usageInputPath: "usage.prompt_tokens",
            usageOutputPath: "usage.completion_tokens",
            usageOptIn: false
        )
    case .sambanova:
        return StreamDef(
            endpoint: "",
            param: "stream",
            paramValue: "true",
            deltaTextPath: "choices[0].delta.content",
            doneSignal: "[DONE]",
            usesEventTypes: false,
            contentEvent: "",
            doneEvent: "",
            usageEvent: "",
            usageInputPath: "usage.prompt_tokens",
            usageOutputPath: "usage.completion_tokens",
            usageOptIn: false
        )
    case .together:
        return StreamDef(
            endpoint: "",
            param: "stream",
            paramValue: "true",
            deltaTextPath: "choices[0].delta.content",
            doneSignal: "[DONE]",
            usesEventTypes: false,
            contentEvent: "",
            doneEvent: "",
            usageEvent: "",
            usageInputPath: "usage.prompt_tokens",
            usageOutputPath: "usage.completion_tokens",
            usageOptIn: false
        )
    case .vllm:
        return StreamDef(
            endpoint: "",
            param: "stream",
            paramValue: "true",
            deltaTextPath: "choices[0].delta.content",
            doneSignal: "[DONE]",
            usesEventTypes: false,
            contentEvent: "",
            doneEvent: "",
            usageEvent: "",
            usageInputPath: "usage.prompt_tokens",
            usageOutputPath: "usage.completion_tokens",
            usageOptIn: false
        )
    case .workersai:
        return StreamDef(
            endpoint: "",
            param: "stream",
            paramValue: "true",
            deltaTextPath: "choices[0].delta.content",
            doneSignal: "[DONE]",
            usesEventTypes: false,
            contentEvent: "",
            doneEvent: "",
            usageEvent: "",
            usageInputPath: "usage.prompt_tokens",
            usageOutputPath: "usage.completion_tokens",
            usageOptIn: false
        )
    case .yi:
        return StreamDef(
            endpoint: "",
            param: "stream",
            paramValue: "true",
            deltaTextPath: "choices[0].delta.content",
            doneSignal: "[DONE]",
            usesEventTypes: false,
            contentEvent: "",
            doneEvent: "",
            usageEvent: "",
            usageInputPath: "usage.prompt_tokens",
            usageOutputPath: "usage.completion_tokens",
            usageOptIn: false
        )
    case .zhipu:
        return StreamDef(
            endpoint: "",
            param: "stream",
            paramValue: "true",
            deltaTextPath: "choices[0].delta.content",
            doneSignal: "[DONE]",
            usesEventTypes: false,
            contentEvent: "",
            doneEvent: "",
            usageEvent: "",
            usageInputPath: "usage.prompt_tokens",
            usageOutputPath: "usage.completion_tokens",
            usageOptIn: false
        )
    default: return nil
    }
}
