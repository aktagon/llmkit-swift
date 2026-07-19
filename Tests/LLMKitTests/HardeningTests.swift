import XCTest
@testable import LLMKit

///
///
///
final class HardeningTests: XCTestCase {
    //

    func testUrlencodeLeavesUnreservedApiKeyUnchanged() {
        //
        //
        //
        XCTAssertEqual(urlencode("test-key_0123456789-abcdefghijklmnop"), "test-key_0123456789-abcdefghijklmnop")
    }

    func testUrlencodePercentEncodesReservedCharacters() {
        XCTAssertEqual(urlencode("key/with+reserved=chars&more?"), "key%2Fwith%2Breserved%3Dchars%26more%3F")
        XCTAssertEqual(urlencode("cursor page 2"), "cursor%20page%202")
    }

    //

    func testUnknownSystemPlacementThrowsUnsupported() {
        let spec = ProviderSpec(
            name: .ai21,
            slug: "ai21",
            baseURL: "https://api.ai21.com",
            endpoint: "/v1/chat/completions",
            defaultModel: "jamba-1.5-large",
            envVar: "AI21_API_KEY",
            defaultMaxTokens: 4096,
            responseTextPath: "choices[0].message.content",
            authScheme: "BearerToken",
            authHeader: "Authorization",
            authPrefix: "Bearer",
            authQueryParam: "",
            requiredHeader: "",
            requiredHeaderValue: "",
            systemPlacement: "SystemAsQueryParam", // not an ontology value
            chatWireShape: "ChatOpenAI",
            chatProtocols: [],
            roleMappings: ["assistant": "assistant", "system": "system", "tool": "tool", "user": "user"],
            usageInputPath: "usage.prompt_tokens",
            usageOutputPath: "usage.completion_tokens",
            reasoningTokensPath: "",
            finishReasonPath: "",
            finishMessagePath: "",
            streamFinishReasonPath: "",
            streamFinishMessagePath: "",
            wrapsOptionsIn: "",
            safetySettingsWirePath: "",
            modelInBody: true,
            errorMessagePath: "error.message",
            errorTypePath: "error.type",
            accessKeyEnvVar: "",
            secretKeyEnvVar: "",
            sessionTokenEnvVar: "",
            regionEnvVar: "",
            serviceName: ""
        )
        XCTAssertThrowsError(
            try RequestBuilder.buildBody(
                config: spec, wireShape: spec.chatWireShape, apiKey: "test-ai21-key",
                model: "jamba-1.5-large", system: "You are a sommelier.",
                msgs: [], tools: [], options: PromptOptions()
            )
        ) { error in
            XCTAssertEqual(
                error as? LLMKitError,
                .unsupported("chat request: unknown system placement \"SystemAsQueryParam\"")
            )
        }
    }
}
