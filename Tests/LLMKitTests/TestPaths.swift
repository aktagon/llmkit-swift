import Foundation
@testable import LLMKit

///
///
enum TestPaths {
    ///
    ///
    static func repoRoot(from file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent() // LLMKitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // swift
            .deletingLastPathComponent() // repo root
    }

    ///
    static func testdata(_ relativePath: String) -> URL {
        repoRoot()
            .appendingPathComponent("codegen/testdata")
            .appendingPathComponent(relativePath)
    }

    ///
    ///
    static func writeRequestArtifact(fixture: String, body: JSONValue) throws {
        let directory = repoRoot()
            .appendingPathComponent("target/wire/request")
            .appendingPathComponent(fixture)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("swift.json")
        try Data(body.serialized().utf8).write(to: file)
    }

    ///
    ///
    ///
    ///
    static func writeRequestHeaders(fixture: String, headers: [String: String]) throws {
        let directory = repoRoot()
            .appendingPathComponent("target/wire/request")
            .appendingPathComponent(fixture)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("swift.headers.json")
        let pairs = headers.keys.sorted().map { (key: String) in (key, JSONValue.string(headers[key]!)) }
        try Data(JSONValue.object(pairs).serialized().utf8).write(to: file)
    }

    ///
    ///
    static func writeResponseArtifact(shape: String, projection: JSONValue) throws {
        let directory = repoRoot()
            .appendingPathComponent("target/wire/response")
            .appendingPathComponent(shape)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("swift.json")
        try Data(projection.serialized().utf8).write(to: file)
    }

    ///
    ///
    ///
    static func writeTelemetryArtifact(fixture: String, payload: String) throws {
        let directory = repoRoot()
            .appendingPathComponent("target/wire/telemetry")
            .appendingPathComponent(fixture)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("swift.json")
        try Data(payload.utf8).write(to: file)
    }

    ///
    ///
    ///
    static func writeCatalogueArtifact(case caseName: String, projection: JSONValue) throws {
        let directory = repoRoot()
            .appendingPathComponent("target/wire/catalogue")
            .appendingPathComponent(caseName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("swift.json")
        try Data(projection.serialized().utf8).write(to: file)
    }

    ///
    ///
    ///
    static func writeSigV4Artifact(fixture: String, projection: JSONValue) throws {
        let directory = repoRoot()
            .appendingPathComponent("target/wire/sigv4")
            .appendingPathComponent(fixture)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("swift.json")
        try Data(projection.serialized().utf8).write(to: file)
    }

    ///
    ///
    ///
    static func writeLifecycleArtifact(fixture: String, projection: JSONValue) throws {
        let directory = repoRoot()
            .appendingPathComponent("target/wire/lifecycle")
            .appendingPathComponent(fixture)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("swift.json")
        try Data(projection.serialized().utf8).write(to: file)
    }
}
