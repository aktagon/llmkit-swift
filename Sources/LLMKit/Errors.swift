import Foundation

/// Library-wide error type (mirrors the Rust `error.rs` variants). Conforms to
/// `LocalizedError` so callers get a human-readable `errorDescription`.
public enum LLMKitError: Error, Equatable, Sendable {
    /// A request, option, or builder field failed pre-flight validation.
    case validation(field: String, message: String)
    /// The provider returned a non-2xx status.
    case api(provider: String, statusCode: Int, message: String)
    /// The transport (URLSession) failed or returned a non-HTTP response.
    case transport(String)
    /// The response body could not be decoded.
    case decoding(String)
}

extension LLMKitError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .validation(field, message):
            return "validation: \(field) - \(message)"
        case let .api(provider, statusCode, message):
            return "\(provider): \(message) (\(statusCode))"
        case let .transport(message):
            return "transport: \(message)"
        case let .decoding(message):
            return "decoding: \(message)"
        }
    }
}
