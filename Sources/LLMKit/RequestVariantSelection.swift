/// Pick the config's wire request by the inputs the request carries (ADR-096):
/// `WithReferenceImages` when it holds at least one image part, else
/// `TextOnly`. A config with no variant for those inputs cannot send the
/// request, so the caller gets a validation error on "parts".
func selectRequestVariant(
    provider: String, variants: [RequestVariant], imageCount: Int
) throws -> RequestVariant {
    let carries = imageCount > 0 ? CarriedInput.withReferenceImages : CarriedInput.textOnly
    if let variant = variants.first(where: { $0.carries == carries }) {
        return variant
    }
    throw LLMKitError.validation(field: "parts", message: "\(provider) has no \(carries) request")
}
