/// Pick the config's wire request by the inputs the request carries (ADR-096):
/// `imageCarries` when it holds at least one image part, else `TextOnly`.
/// The capability names what its image parts are: `WithReferenceImages` for
/// image, `WithSeedFrame` for video. A config with no variant for those
/// inputs cannot send the request, so the caller gets a validation error on
/// "parts".
func selectRequestVariant(
    provider: String, variants: [RequestVariant], imageCount: Int, imageCarries: String
) throws -> RequestVariant {
    let carries = imageCount > 0 ? imageCarries : CarriedInput.textOnly
    if let variant = variants.first(where: { $0.carries == carries }) {
        return variant
    }
    throw LLMKitError.validation(field: "parts", message: "\(provider) has no \(carries) request")
}
