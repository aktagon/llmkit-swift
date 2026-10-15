// Code generated — DO NOT EDIT.

import Foundation

///
/// declarations onto the handwritten builder structs. Each mutates
/// through that builder's internal `with` clone-on-chain helper, so a
/// generated method and a handwritten one are indistinguishable to a
/// caller. The handwritten setters that remain are tracked by
///
/// declared surface is complete across the two files, never in one.

extension Text {
    /// history replaces the conversation history for this call.
    ///
    /// ADR-085 RSN-005 — a message you author here carries no captured
    /// provider payload, so an assistant turn with tool calls is rebuilt from
    /// its role, content and tool calls alone, and any reasoning the provider
    /// returned with that turn is absent from the next request. To preserve
    /// it, pass back the messages this SDK produced rather than
    /// reconstructing them by hand.
    public func history(_ msgs: Message...) -> Text { with { $0.historyMsgs = msgs } }

    /// raw opts into the parsed provider body on the response (ADR-014).
    public func raw() -> Text { with { $0.rawOptIn = true } }

    /// text appends an ordered text part. The terminal's own argument is appended
    /// after these, so the request reads in caller order.
    public func text(_ value: String) -> Text { with { $0.textParts.append(value) } }
}

extension Image {
    /// raw opts into the parsed provider body on the response (ADR-014).
    public func raw() -> Image { with { $0.options.raw = true } }

    /// safetyFilter sets a single image safety threshold. Every image provider rejects it
    /// with a validation error.
    ///
    /// Deprecated: no provider accepts this since 2026-10-15 (Vertex Imagen
    /// shut down, BUG-101); removed at the next major.
    public func safetyFilter(_ value: String) -> Image { with { $0.options.safetyFilter = value } }

    /// safetySettings sets the per-category safety thresholds (Google).
    public func safetySettings(_ values: [SafetySetting]) -> Image { with { $0.options.safetySettings = values } }

    /// text appends an ordered text part. The terminal's own argument is appended
    /// after these, so the request reads in caller order.
    public func text(_ value: String) -> Image { with { $0.textParts.append(value) } }
}

extension Video {
    /// text appends an ordered text part. The terminal's own argument is appended
    /// after these, so the request reads in caller order.
    public func text(_ value: String) -> Video { with { $0.textParts.append(value) } }
}
