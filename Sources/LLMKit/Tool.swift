import Foundation

///
///
///
///
public struct Tool: Sendable {
    ///
    public let name: String

    ///
    public let description: String

    ///
    ///
    public let schema: JSONValue

    ///
    ///
    public let run: @Sendable (JSONValue) throws -> String

    public init(
        name: String,
        description: String,
        schema: JSONValue,
        run: @escaping @Sendable (JSONValue) throws -> String
    ) {
        self.name = name
        self.description = description
        self.schema = schema
        self.run = run
    }
}
