/// Pick the config's wire request whose carried inputs equal `carries`, in any
/// order (ADR-096). A first-and-last-frame request carries two inputs. A
/// config with no variant for those inputs cannot send the request, so the
/// caller gets a validation error on "parts".
func selectRequestVariant(
    provider: String, variants: [RequestVariant], carries: [String]
) throws -> RequestVariant {
    if let variant = variants.first(where: { Set($0.carries) == Set(carries) && $0.carries.count == carries.count }) {
        return variant
    }
    throw LLMKitError.validation(
        field: "parts", message: "\(provider) has no \(carries.joined(separator: "+")) request")
}

/// The carried input of a request with `imageCount` image parts: `imageInput`
/// when it holds at least one, else `TextOnly`. The capability names what its
/// image parts are: `WithReferenceImages` for image, `WithSeedFrame` for video.
func partsCarry(imageCount: Int, imageInput: String) -> [String] {
    imageCount > 0 ? [imageInput] : [CarriedInput.textOnly]
}
