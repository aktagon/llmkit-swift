import Foundation

///
///
public enum LLMKitError: Error, Equatable, Sendable {
    ///
    case validation(field: String, message: String)
    ///
    case api(provider: String, statusCode: Int, message: String)
    ///
    case transport(String)
    ///
    case decoding(String)
    ///
    ///
    case unsupported(String)
    ///
    ///
    case pollTimeout(provider: String, id: String)
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
        case let .unsupported(message):
            return message
        case let .pollTimeout(provider, id):
            return "\(provider): job \(id) timed out"
        }
    }
}
