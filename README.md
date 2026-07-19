# llmkit (Swift)

One Swift API for Anthropic, OpenAI, Google, and 30+ other providers — including local models through Ollama and vLLM. Switch providers without rewriting your request.

Async/await, built on Foundation and `URLSession`. No third-party dependencies. Apple platforms (macOS 12+, iOS 15+), Swift 5.9+.

Also available for Go, TypeScript, Python, Rust, and Java.

<p align="center">
  <img src="https://raw.githubusercontent.com/aktagon/llmkit-swift/master/assets/logos/llmkit-languages.svg" alt="Go, TypeScript, Python, Rust, Swift, Java" height="26">
</p>
<p align="center">
  <img src="https://raw.githubusercontent.com/aktagon/llmkit-swift/master/assets/logos/llmkit-providers.svg" alt="Anthropic, OpenAI, Google, and 26 more providers" height="26">
</p>

## Install

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/aktagon/llmkit-swift.git", from: "1.0.0")
]
```

and depend on the `LLMKit` product from your target.

## Quick Start

```swift
import LLMKit

let client = Client(provider: .anthropic, apiKey: ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? "")
let resp = try await client.text
    .system("Be concise.")
    .temperature(0.3)
    .prompt("Why is the sky blue?")

print(resp.text)
print("\(resp.usage.input) input tokens")
```

One mental model — `client.<capability>.<chain>.<terminal>` — across every capability.

The code blocks below marked as included snippets are extracted from test-executed source, so the call shapes shown here are guaranteed to run against the real API surface.

## Providers

Construct a client with any `ProviderName` case:

```swift
let anthropic = Client(provider: .anthropic, apiKey: key)
let openai = Client(provider: .openai, apiKey: key)
let google = Client(provider: .google, apiKey: key)
let ollama = Client(provider: .ollama, apiKey: "")
```

36 providers, four chat API shapes (OpenAI-compatible, Anthropic Messages, Google Generative AI, AWS Bedrock Converse), plus dedicated image, video, music, speech, and transcription providers. Bedrock auth uses SigV4; other providers use API-key auth.

## API

### Text — one-shot prompt

```swift
let resp = try await client.text
    .system("You are helpful")
    .temperature(0.7)
    .maxTokens(200)
    .prompt("What is 2+2?")

print(resp.text)              // "4"
print(resp.usage.input)       // prompt tokens
print(resp.usage.output)      // completion tokens
print(resp.usage.cacheRead)   // tokens served from cache
print(resp.usage.cacheWrite)  // tokens written to cache (Anthropic explicit)
print(resp.usage.reasoning)   // internal reasoning tokens (OpenAI o-series, Gemini 2.5+)
```

Capability-scoped fields (`cacheRead`, `cacheWrite`, `reasoning`) are zero when the provider doesn't report them separately.

### Stream — callback + trailing response

The callback fires for each chunk; the awaited terminal returns the final `Response` with token counts.

<!-- llmkit:include swift/Tests/LLMKitTests/ExampleSnippetsTests.swift#stream -->
```swift
let resp = try await client.text
    .system("Be brief")
    .stream("Tell me a joke") { chunk in
        print(chunk, terminator: "")
    }

print("\nUsage: \(resp.usage.input) in / \(resp.usage.output) out")
```

### Agent — tool loop

```swift
let add = Tool(
    name: "add",
    description: "Add two numbers",
    schema: try JSONValue.parse(#"{"type":"object","properties":{"a":{"type":"number"},"b":{"type":"number"}}}"#),
    run: { args in
        String(args.doubleValue(at: "a") + args.doubleValue(at: "b"))
    }
)

let bot = client.agent()
    .system("You are a calculator.")
    .addTool(add)
    .maxToolIterations(5)

let resp = try await bot.prompt("What is 2+3?")
print(resp.text)
```

`Agent` is **stateful** — repeated `bot.prompt(...)` calls accumulate conversation history. `Tool.run` is `async throws`, so a tool can await its own network or file work without blocking the cooperative thread pool.

Tool dispatch covers Anthropic `tool_use`, OpenAI `tool_calls`, Google `functionCall`, and Bedrock Converse `toolUse`.

### Image input (vision)

Attach an image to a text prompt with `.image(mimeType, data)`; it is sent as the provider's native image block (works on Anthropic, OpenAI, Google, and Bedrock). Bytes-based, so no filesystem is required:

```swift
let resp = try await client.text
    .image("image/png", screenshotData)
    .prompt("Describe this screenshot in one sentence.")
```

Reference an already-uploaded file by id with `.file(id)` (see Upload below).

### Image — text-to-image

Supports Google's Nano Banana 2 (`gemini-3.1-flash-image-preview`) and Pro (`gemini-3-pro-image-preview`); OpenAI's `gpt-image-2`, `gpt-image-1.5`, `gpt-image-1`, and `gpt-image-1-mini`; xAI's `grok-imagine-image-quality`; Google Cloud Vertex AI's Imagen 3 / Imagen 4.

```swift
let google = Client(provider: .google, apiKey: key)
let img = try await google.image
    .model("gemini-3.1-flash-image-preview")
    .aspectRatio("16:9")
    .imageSize("2K")
    .generate("A nano banana dish, studio lighting")

try Data(img.images[0].bytes).write(to: URL(fileURLWithPath: "out.png"))
```

For editing, attach reference images with `.image(mimeType, data)` before the terminal. Aspect ratios and sizes validate against a per-model whitelist before the HTTP request; empty whitelists mean "no client-side check; pass through". Provider-specific knobs are typed chain methods — `.quality(_:)`, `.outputFormat(_:)`, `.background(_:)`, `.count(_:)` — validated per provider: calling `.quality(...)` on a Google builder throws a validation error immediately, no HTTP round-trip.

### Music — text-to-music

Generate audio from a text prompt via `client.music`. Decoded audio bytes come back on `resp.audio[0].bytes`. Models that support vocals take lyrics via `.lyrics(...)` (use section tags like `[verse]`).

<!-- llmkit:include swift/Tests/LLMKitTests/ExampleSnippetsTests.swift#music -->
```swift
let resp = try await client.music
    .model("music-2.6")
    .generate("a calm instrumental, warm piano and soft strings")

if let first = resp.audio.first {
    print("\(first.bytes.count) audio bytes (\(first.mimeType))")
}
```

| Provider | Model(s)                                      | Lyrics | Output     |
| -------- | --------------------------------------------- | ------ | ---------- |
| Vertex   | `lyria-002`                                   | no     | WAV (~30s) |
| Google   | `lyria-3-pro-preview`, `lyria-3-clip-preview` | yes    | MP3        |
| MiniMax  | `music-2.6`                                   | yes    | MP3        |

### Video — text-to-video

Video generation is asynchronous: `submit` returns a job immediately, and `job.wait()` polls until it finishes. The result carries a temporary hosted URL on `resp.videos[0].url` — download it yourself. `job.poll()` is the single-round-trip primitive when you want to drive the loop.

<!-- llmkit:include swift/Tests/LLMKitTests/ExampleSnippetsTests.swift#video -->
```swift
let job = try await client.video
    .model("grok-imagine-video")
    .submit("a slow cinematic drone shot flying over snow-capped alpine peaks at golden hour")
let resp = try await job.wait()

if let first = resp.videos.first {
    print("url=\(first.url) duration=\(first.durationSeconds)s")
}
```

Image-to-video: seed with `.image(mimeType, data)` before `.submit(...)` on models that support it.

### Speech — text-to-speech

```swift
let resp = try await client.speech
    .model("inworld-tts-2")
    .voice("Dennis")
    .generate("Welcome aboard, and mind the gap.")

try Data(resp.audio.bytes).write(to: URL(fileURLWithPath: "out.mp3"))
```

### Transcription — speech-to-text

Synchronous providers (OpenAI) return the transcript directly; asynchronous providers (AssemblyAI) return a job to wait on.

```swift
// Synchronous (OpenAI Whisper / gpt-4o-transcribe)
let t = try await client.transcription
    .model("gpt-4o-transcribe")
    .transcribe([Part.audioBytes(mimeType: "audio/mpeg", data: clip)])
print(t.text)

// Asynchronous (AssemblyAI)
let job = try await client.transcription
    .submit([Part.audio(url: "https://storage.example.com/clip.mp3")])
let result = try await job.wait()
```

### Upload — path or bytes

```swift
// from a path
let file = try await client.upload().path("./data.pdf").run()

// from bytes (filename required)
let file2 = try await client.upload()
    .bytes(buf)
    .filename("report.pdf")
    .mimeType("application/pdf")
    .run()

// reference the uploaded file in a later prompt
let resp = try await client.text.file(file.id).prompt("Summarize this document.")
```

### Batches

`batch(...)` queues the prompts and returns a job; `job.wait()` blocks until completion, returning the parsed responses in prompt order.

<!-- llmkit:include swift/Tests/LLMKitTests/ExampleSnippetsTests.swift#batch -->
```swift
let job = try await client.text
    .system("Be brief")
    .batch(
        "Translate hello to French",
        "Translate hello to Spanish"
    )
let results = try await job.wait()
for r in results { print(r.text) }
```

Both inline (Anthropic) and file-reference (OpenAI two-hop) flows are handled internally.

### Caching

```swift
// Anthropic — explicit cache_control wrap of the system prompt.
_ = try await client.text.system(longSystemPrompt).caching().prompt("...")

// OpenAI — automatic server-side caching (caching() is a hint; reads
// surface in resp.usage.cacheRead regardless).
_ = try await client.text.system(longSystemPrompt).caching().prompt("...")

// Google — pre-flight POST creates a cachedContents resource, then the
// main call references it. Google requires ~1k+ tokens of system prompt.
_ = try await client.text.system(bigSystemPrompt).caching().prompt("...")
```

The mode is provider-specific and inferred from the provider config. Override the cache TTL with `.cacheTtl(seconds)` where the provider supports one.

### Model catalogue

`client.models` and `client.providers` cover model discovery in three modes:

```swift
// 1. Compiled-in catalogue — synchronous, no HTTP.
let all = client.models.list()
let info = client.models.get("claude-opus-4-7")   // ModelInfo?
let chat = client.models.withCapability(.chatCompletion).list()

// 2. Providers namespace.
let providers = client.providers.list()

// 3. Live + scoped HTTP.
let live = await client.models.live()             // fan-out; partial success is normal
let scoped = try await client.models.provider(.anthropic).list()
let raw = try await client.models.provider(.anthropic).raw().list()  // ModelInfo.raw populated
```

`live()` calls every configured provider's models endpoint in parallel and aggregates results into `LiveResult.models` plus a per-provider `LiveResult.errors` map. `raw()` opts into populating `ModelInfo.raw` with the provider-native record.

### Capability query

```swift
if client.supports(.caching) {
    // safe to chain .caching() on this provider
}
```

`Capability` covers `chatCompletion`, `imageGeneration`, `toolCalling`, `fileUpload`, `batching`, `caching`, `reasoning`, and `catalogue`.

## Options

Across the `Text` builder:

| Concept          | Method                    |
| ---------------- | ------------------------- |
| System prompt    | `.system(s)`              |
| Model override   | `.model(name)`            |
| Sampling         | `.temperature(t)`         |
| Token cap        | `.maxTokens(n)`           |
| Caching          | `.caching()`              |
| Middleware hooks | `.addMiddleware(fn)`      |
| Reasoning effort | `.reasoningEffort(l)`     |
| Thinking budget  | `.thinkingBudget(n)`      |
| Structured output| `.schema(json)`           |

Sampling hyperparameters (`.topP`, `.topK`, `.seed`, `.frequencyPenalty`, `.presencePenalty`, `.stopSequences`) are validated per provider; unsupported options throw a validation error naming the wire field rather than silently dropping. Gemini content filtering is available via `.safetySettings([SafetySetting(category:threshold:)])`.

`Agent` adds `.addTool(t)` and `.maxToolIterations(n)` and carries conversation history implicitly across `.prompt(...)` calls.

## Self-hosted endpoints

```swift
let client = Client(provider: .openai, apiKey: "anything")
    .baseURL("http://localhost:8080/v1")
```

Works for any OpenAI-compatible server (vLLM, LM Studio, Ollama, corporate gateways).

## Custom headers

Attach a custom HTTP header to every request — for example an authenticated gateway that needs its own auth header alongside the provider key. `addHeader` is chainable and calls accumulate.

```swift
let client = Client(provider: .anthropic, apiKey: key)
    .baseURL("https://gateway.example.com/anthropic")
    .addHeader("cf-aig-authorization", "Bearer \(gatewayToken)")
```

The custom header is sent in addition to the provider's auth header; it cannot override the provider auth header or the required version header.

## Middleware

Register pre/post hooks around LLM requests, tool calls, image generation, cache creation, uploads, and batch submits. Pre-phase middleware can veto by returning an error; post-phase return values are discarded.

```swift
// Observation: log token usage after every LLM request.
let logUsage: MiddlewareFn = { event in
    if event.op == .llmRequest, event.phase == .post, let usage = event.usage {
        print("\(event.provider)/\(event.model): \(usage.input) in, \(usage.output) out")
    }
    return nil
}

// Veto: abort before the HTTP request (pre-phase).
let budgetGate: MiddlewareFn = { event in
    if event.op == .llmRequest, event.phase == .pre, budgetExceeded {
        return LLMKitError.middlewareVeto("daily budget exceeded")
    }
    return nil
}

let resp = try await client.text
    .addMiddleware(budgetGate)
    .addMiddleware(logUsage)
    .prompt("...")
```

A pre-phase veto surfaces as a middleware-veto error carrying the cause, so callers can discriminate it from transport or provider errors. Middleware fires in registration order; the first non-nil pre-phase return aborts.

## Telemetry

Opt-in OpenTelemetry. Attach a `Telemetry` and every call — success and rejection alike — produces one OTEL GenAI span (operation, provider, model, token usage, and `error.type` on failure) as standards-compliant OTLP/JSON bytes. llmkit builds the span; you decide where the bytes go. Off unless attached.

```swift
// Batteries: POST every span to an OTLP collector.
let client = Client(provider: .openai, apiKey: key)
    .addTelemetry(Telemetry(export: Telemetry.httpExport(endpoint: "https://collector:4318")))

// Or bring your own transport — hand the bytes to your OTEL pipeline:
let custom = Client(provider: .openai, apiKey: key)
    .addTelemetry(Telemetry(export: { payload in spanQueue.enqueue(payload) }))
```

`httpExport` is a fail-open, fire-and-forget POST (inject your own `URLSession` via its `session` parameter if you need a custom transport); for high volume hand your own callback into your OTEL SDK's batch processor. The same OTLP span shape is emitted byte-for-byte across all six SDKs. Because `export` is a required field, an enabled-but-no-sink `Telemetry` cannot be constructed.

## Mirror

This repo is a read-only mirror of a private monorepo. File issues here; code patches should target the private source via `christian@aktagon.com`.

## License

MIT
