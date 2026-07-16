import XCTest
@testable import LLMKit

/// Cross-SDK catalogue request-URL conformance (ADR-067 Fix B / CAT-006) — the
/// Swift driver. The REQUEST-side sibling of ResponseWireTests (which locks the
/// /models PARSE seam): for a fixed (provider, cursor), every SDK's
/// catalogue-list path must assemble a byte-identical {method, url, headers}.
///
/// The driver calls the SAME URL/header-assembly seam the paginate loop uses
/// (buildCatalogueURL + appendCursor + buildCatalogueHeaders, reachable via
/// @testable import). The cursorParam comes from the generated catalogueConfig,
/// NOT from inputs.json — so this exercises the generated config. Drops
/// target/wire/catalogue/<case>/swift.json for the cross-SDK comparator
/// (codegen/test_cross_sdk_catalogue.py) and asserts value-equality in-driver.
final class CatalogueWireTests: XCTestCase {
    func testCatalogueWire() throws {
        let inputsText = try String(
            contentsOf: TestPaths.testdata("wire/catalogue/v1/inputs.json"), encoding: .utf8
        )
        let inputs = try JSONValue.parse(inputsText)
        guard case let .object(top) = inputs,
              let apiKeyValue = top.first(where: { $0.0 == "apiKey" })?.1,
              case let .string(apiKey) = apiKeyValue,
              let casesValue = top.first(where: { $0.0 == "cases" })?.1,
              case let .object(cases) = casesValue
        else {
            return XCTFail("malformed catalogue inputs.json")
        }

        for (caseName, caseValue) in cases {
            guard case let .object(fields) = caseValue,
                  case let .string(providerSlug)? = fields.first(where: { $0.0 == "provider" })?.1,
                  case let .string(cursor)? = fields.first(where: { $0.0 == "cursor" })?.1,
                  let providerName = ProviderName(rawValue: providerSlug)
            else {
                return XCTFail("malformed case \(caseName)")
            }

            let client = Client(provider: providerName, apiKey: apiKey)
            let scoped = client.models.provider(providerName)
            let pcfg = providerConfig(providerName)
            guard let cfg = catalogueConfig(providerName) else {
                return XCTFail("no catalogue config for \(providerSlug)")
            }

            let url = appendCursor(
                buildCatalogueURL(scoped: scoped, pcfg: pcfg, endpoint: cfg.endpoint),
                cfg.cursorParam, cursor
            )
            let headers = buildCatalogueHeaders(scoped: scoped, pcfg: pcfg)

            let projection = JSONValue.object([
                ("method", .string("GET")),
                ("url", .string(url)),
                ("headers", .object(headers.map { ($0.0, JSONValue.string($0.1)) })),
            ])

            try TestPaths.writeCatalogueArtifact(case: caseName, projection: projection)

            let goldenText = try String(
                contentsOf: TestPaths.testdata("wire/catalogue/v1/\(caseName).json"), encoding: .utf8
            )
            XCTAssertEqual(
                projection, try JSONValue.parse(goldenText),
                "\(caseName) request differs from shared golden"
            )
        }
    }
}
