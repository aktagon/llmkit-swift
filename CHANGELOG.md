# Changelog

All notable changes to the Swift SDK are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **BREAKING — an unreported usage dimension or finish signal is now absent, not zero.**
  The six `Usage` dimensions (input, output, cache read, cache write, reasoning,
  cost) and the finish reason / finish message on every response container are
  now `Int?` / `Double?` / `String?`. Previously a provider that reported no
  cached tokens and one that never mentioned caching both produced `0`, and an
  unreported cost read as a free request.

  Migration: `resp.usage.input` is now `Int?`; bind with `if let` rather than treating a missing count as `0`.

  Aggregation across agent turns is **absorbing** — a total is reported only when
  every turn reported that dimension, so a partial sum is never presented as a
  total. Telemetry now exports a usage attribute when the value is *reported*,
  zero included, instead of when it is greater than zero.

### Added

- `batchSlotMissing` and `batchSlotError`: the finish reasons of a batch slot with no result, and of a
  failed slot the provider gave no reason for. Compare against them instead
  of typing the strings.

### Fixed

- **`raw()` now reaches batch results.** `text.raw().batch(...)` used to drop
  the opt-in, so every returned `Response.raw` was `nil`. Each batch response
  now carries its provider body.
- **OpenAI batch failures show the provider's error.** Waiting on an OpenAI
  batch now also reads its error file. A failed request's finish reason is the
  provider's error code (for example `batch_expired`), and its finish message
  is the provider's error message.
- **A batch result succeeds only when the provider says it did.** A result line
  with a failure status and an empty body reads as failed, not as a success
  with empty text.
- **A batch returns one response per prompt, even when the last one has no
  result.** The list length comes from the batch's request count, so a missing
  last request keeps its slot and reads `missing`.
- **Batch results are matched to prompts by request id, not by line order.**
  Providers return batch results in any order, and a failed request used to be
  dropped, so later answers moved up one place. Waiting on a batch now returns
  one response per prompt, at the prompt's index. A failed request keeps its
  slot with empty text, the provider's result status as the finish reason
  (`errored`, `expired`, `canceled`, or `error`) and the provider's error
  message as the finish message. A request with no result reads finish reason
  `missing`. Results for request ids this SDK did not assign follow in file
  order.

## [1.0.1] — 2026-07-19

### Security

- Fixed: an API key could appear in error output. On a URL-parse failure for a query-parameter-authenticated provider (Google), the validation error embedded the full request URL — which carries the key as a `?key=` query parameter. The message no longer includes the URL. (Note: on a network-level failure, Foundation's own `NSError` may still carry the URL in its `userInfo`; avoid logging raw transport errors with `print(error)` / `String(describing:)`.)

## [1.0.0] — 2026-07-19

First release. Apple-only (Foundation + CryptoKit + URLSession, no external
dependencies), distributed via SwiftPM. Born on the post-ADR-064 API so it
enters the pack at parity with the other SDKs' v2.0.0/v3.0.0 line.

### Added

- Chat completion — `c.text.system(...).prompt(...)`, with `stream`, `agent`
  (tool loop), and `batch` execution modes on the `Text` builder. `batch(...)`
  returns a `BatchHandle`; `handle.wait()` resolves the ordered results.
- Media capabilities — image generation, video generation (async handle),
  speech (TTS) and music generation, and transcription (STT, async handle).
- File upload — `c.upload.path(...)` / `.bytes(...)` returns a `File` id to
  attach to later requests.
- Prompt caching, request/response middleware (observation + veto), and
  opt-in OpenTelemetry (OTLP/HTTP) telemetry with a typed `error.type`.
- Model catalogue — `c.models` / `c.providers` (compiled-in metadata plus a
  `live()` path), and the keyless `*GenConfig` accessors.
- Typed provider identity and `c.supports(_:)` capability checks.
