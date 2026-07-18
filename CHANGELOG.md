# Changelog

All notable changes to the Swift SDK are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
