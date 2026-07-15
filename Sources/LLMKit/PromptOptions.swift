import Foundation

///
///
public struct SafetySetting: Sendable, Equatable {
    public let category: String
    public let threshold: String

    public init(category: String, threshold: String) {
        self.category = category
        self.threshold = threshold
    }
}

///
///
///
struct PromptOptions: Sendable {
    ///
    ///
    var caching: Bool = false
    ///
    var cacheTtl: Int?
    ///
    var middleware: [MiddlewareFn] = []
    var maxTokens: Int?
    var temperature: Double?
    var topP: Double?
    var topK: Int?
    var seed: Int64?
    var frequencyPenalty: Double?
    var presencePenalty: Double?
    var thinkingBudget: Int?
    var reasoningEffort: String?
    var stopSequences: [String] = []
    var safetySettings: [SafetySetting] = []
    ///
    var proto: String = ""
    ///
    var schema: String?
}
