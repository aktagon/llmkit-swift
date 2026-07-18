import Foundation
import CryptoKit

/// AWS Signature Version 4 signing for Bedrock (ADR SigV4 auth scheme). A
/// port of `go/sigv4.go`, using CryptoKit for HMAC-SHA256 / SHA256 so the SDK
/// stays dependency-free. Returns the headers to add to the outbound request;
/// the timestamp is the only non-deterministic signing input, so the CR-002
/// wire driver (`SigV4WireTests`) injects a frozen clock and asserts the
/// canonical request / string-to-sign / Authorization byte-identically against
/// the shared golden at `codegen/testdata/wire/sigv4/v1/`.
enum SigV4 {
    /// The intermediate signing artifacts. Production callers use only
    /// `headers`; the wire driver asserts the other three against the golden.
    struct Parts {
        let headers: [(String, String)]
        let canonicalRequest: String
        let stringToSign: String
        let authorization: String
    }

    /// Compute the SigV4 headers for a request. `contentType` is folded into
    /// the signed set only when non-empty: AWS recomputes the canonical request
    /// from the headers actually received, so signing a Content-Type on a
    /// request that never sends one (a bodyless GET) is a guaranteed 403.
    static func sign(
        method: String,
        url: URL,
        body: Data,
        accessKey: String,
        secretKey: String,
        sessionToken: String,
        region: String,
        service: String,
        contentType: String,
        now: Date = Date()
    ) -> [(String, String)] {
        signParts(
            method: method, url: url, body: body,
            accessKey: accessKey, secretKey: secretKey, sessionToken: sessionToken,
            region: region, service: service, contentType: contentType, now: now
        ).headers
    }

    /// `sign` with the artifacts exposed (CR-002 clock seam): a fixed `now`
    /// makes the whole signature chain reproducible for the cross-SDK golden.
    static func signParts(
        method: String,
        url: URL,
        body: Data,
        accessKey: String,
        secretKey: String,
        sessionToken: String,
        region: String,
        service: String,
        contentType: String,
        now: Date
    ) -> Parts {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let comps = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        let datestamp = String(format: "%04d%02d%02d", comps.year!, comps.month!, comps.day!)
        let amzdate = String(format: "%@T%02d%02d%02dZ", datestamp, comps.hour!, comps.minute!, comps.second!)

        // Host includes an explicit non-default port (Bedrock over https:443
        // has none, so this is a no-op there but faithful to Go's req.Host).
        let host = url.port.map { "\(url.host ?? ""):\($0)" } ?? (url.host ?? "")
        let payloadHash = sha256Hex(body)

        // The signed header set (lowercased names, sorted). Values are trimmed.
        // content-type only when the request actually sends one (see `sign`).
        var signed: [(String, String)] = [
            ("host", host),
            ("x-amz-content-sha256", payloadHash),
            ("x-amz-date", amzdate),
        ]
        if !contentType.isEmpty {
            signed.append(("content-type", contentType))
        }
        if !sessionToken.isEmpty {
            signed.append(("x-amz-security-token", sessionToken))
        }
        signed.sort { $0.0 < $1.0 }

        let signedHeaders = signed.map(\.0).joined(separator: ";")
        let canonicalHeaders = signed.map { "\($0.0):\($0.1.trimmingCharacters(in: .whitespaces))\n" }.joined()

        // Sign the percent-ENCODED path (the bytes on the wire), not Foundation's
        // decoded `url.path`, so an encoded path segment (e.g. a Bedrock ARN)
        // canonicalizes to what the server receives (mirror of Go's EscapedPath).
        let encodedPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
        let canonicalURI = encodedPath.isEmpty ? "/" : encodedPath
        let canonicalQuery = canonicalQueryString(url)

        let canonicalRequest = [
            method,
            canonicalURI,
            canonicalQuery,
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")

        let credentialScope = "\(datestamp)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzdate,
            credentialScope,
            sha256Hex(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        let signingKey = deriveSigningKey(secretKey: secretKey, datestamp: datestamp, region: region, service: service)
        let signature = hexEncode(hmac(key: signingKey, data: Data(stringToSign.utf8)))

        let authorization = "AWS4-HMAC-SHA256 Credential=\(accessKey)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"

        var headers: [(String, String)] = [
            ("X-Amz-Date", amzdate),
            ("X-Amz-Content-Sha256", payloadHash),
            ("Host", host),
            ("Authorization", authorization),
        ]
        if !sessionToken.isEmpty {
            headers.append(("X-Amz-Security-Token", sessionToken))
        }
        return Parts(
            headers: headers,
            canonicalRequest: canonicalRequest,
            stringToSign: stringToSign,
            authorization: authorization
        )
    }

    private static func canonicalQueryString(_ url: URL) -> String {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems, !items.isEmpty else {
            return ""
        }
        return items
            .map { ($0.name, $0.value ?? "") }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")
    }

    private static func deriveSigningKey(secretKey: String, datestamp: String, region: String, service: String) -> Data {
        let kDate = hmac(key: Data("AWS4\(secretKey)".utf8), data: Data(datestamp.utf8))
        let kRegion = hmac(key: kDate, data: Data(region.utf8))
        let kService = hmac(key: kRegion, data: Data(service.utf8))
        return hmac(key: kService, data: Data("aws4_request".utf8))
    }

    private static func hmac(key: Data, data: Data) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))
        return Data(mac)
    }

    private static func sha256Hex(_ data: Data) -> String {
        hexEncode(Data(SHA256.hash(data: data)))
    }

    private static func hexEncode(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
