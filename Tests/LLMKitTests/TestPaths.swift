import Foundation
@testable import LLMKit

/// Locates repo-root artifacts (shared wire goldens, driver output) from a test
/// file's compile-time path, independent of the process working directory.
enum TestPaths {
    /// The monorepo root: `.../swift/Tests/LLMKitTests/<file>` is four levels
    /// below it.
    static func repoRoot(from file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent() // LLMKitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // swift
            .deletingLastPathComponent() // repo root
    }

    /// A path under `codegen/testdata/`.
    static func testdata(_ relativePath: String) -> URL {
        repoRoot()
            .appendingPathComponent("codegen/testdata")
            .appendingPathComponent(relativePath)
    }

    /// Write a request-wire artifact to `target/wire/request/<fixture>/swift.json`,
    /// mirroring the Rust driver's `rust.json` output.
    static func writeRequestArtifact(fixture: String, body: JSONValue) throws {
        let directory = repoRoot()
            .appendingPathComponent("target/wire/request")
            .appendingPathComponent(fixture)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("swift.json")
        let data = Data(body.serialized().utf8)
        try data.write(to: file)
    }
}
