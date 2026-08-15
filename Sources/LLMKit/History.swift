import Foundation

/// Lowering of caller-supplied conversation history (`Text.history(...)`,
/// `Agent` state) onto the internal turn union the transform layer consumes.
///
/// `Message` is the public, cross-SDK turn record (an ADR-018 generated struct);
/// `Transforms.Msg` is the internal union the per-provider message builders
/// switch on. They are deliberately different types — `Message` is a flat record
/// so it round-trips through Save/Load unchanged, while `Msg` is discriminated so
/// the transforms cannot read a field the turn does not carry.
///
/// The mapping is the same discrimination order every SDK uses, and the order
/// matters: a turn carrying a provider payload is replayed verbatim (ADR-085)
/// before any reconstruction is attempted, and a tool turn is checked before a
/// text turn because a tool result's `content` is empty by construction.
///
/// This lives in its own file rather than in `Transforms.swift` so the two
/// evolve independently — the transform layer is per-provider wire assembly,
/// this is a pure type projection with no provider knowledge at all.
extension Transforms {
    /// Project one public `Message` onto the internal turn union.
    static func msg(from message: Message) -> Msg {
        let fallback: Msg
        if let result = message.toolResult {
            fallback = .result(result)
        } else if !message.toolCalls.isEmpty {
            fallback = .calls(message.toolCalls)
        } else {
            fallback = .text(role: message.role, text: message.content)
        }

        // ADR-085: replay the provider's own serialization when the turn carries
        // one, keeping the projection above as the fallback so a payload captured
        // under a different wire shape drops back to reconstruction rather than
        // going out mis-shaped.
        guard let turn = message.providerTurn else { return fallback }
        return .turn(shape: turn.wireShape, wire: turn.wire, fallback: fallback)
    }

    /// Project a caller's history in order. Empty in, empty out — a chain that
    /// never called `.history(...)` produces exactly the single-turn request it
    /// produced before the option existed.
    static func msgs(from history: [Message]) -> [Msg] {
        history.map(msg(from:))
    }
}
