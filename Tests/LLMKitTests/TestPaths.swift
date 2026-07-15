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
        try Data(body.serialized().utf8).write(to: file)
    }

    /// Write a request-wire HEADER artifact to
    /// `target/wire/request/<fixture>/swift.headers.json` (lowercased keys), the
    /// per-SDK companion the comparator subset-matches against a fixture's
    /// `<fixture>.headers.json` golden (HANDOFF-028 / BUG-017).
    static func writeRequestHeaders(fixture: String, headers: [String: String]) throws {
        let directory = repoRoot()
            .appendingPathComponent("target/wire/request")
            .appendingPathComponent(fixture)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("swift.headers.json")
        let pairs = headers.keys.sorted().map { (key: String) in (key, JSONValue.string(headers[key]!)) }
        try Data(JSONValue.object(pairs).serialized().utf8).write(to: file)
    }

    /// Write a response-wire artifact to `target/wire/response/<shape>/swift.json`,
    /// mirroring the Rust driver's `rust.json` output.
    static func writeResponseArtifact(shape: String, projection: JSONValue) throws {
        let directory = repoRoot()
            .appendingPathComponent("target/wire/response")
            .appendingPathComponent(shape)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("swift.json")
        try Data(projection.serialized().utf8).write(to: file)
    }

    /// Write a lifecycle-wire artifact to
    /// `target/wire/lifecycle/<fixture>/swift.json` (the normalized JobStatus
    /// projection), mirroring the Rust driver's `rust.json` output.
    static func writeLifecycleArtifact(fixture: String, projection: JSONValue) throws {
        let directory = repoRoot()
            .appendingPathComponent("target/wire/lifecycle")
            .appendingPathComponent(fixture)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("swift.json")
        try Data(projection.serialized().utf8).write(to: file)
    }
}
