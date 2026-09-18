import Foundation

private enum Failure: Error, CustomStringConvertible {
    case failed(String)
    var description: String { switch self { case .failed(let message): return message } }
}
private func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw Failure.failed(message) }
}
private func expect(_ expected: GitHubUpdateError, _ message: String, operation: () throws -> Void) throws {
    do { try operation() }
    catch let error as GitHubUpdateError {
        try require(error == expected, message + " (wrong error)")
        return
    }
    throw Failure.failed(message + " (unexpected success)")
}

@main
struct GitHubUpdateSourceTests {
    static let repository = "calvinh99/ScholarsEye"
    static let asset = "https://api.github.com/repos/calvinh99/ScholarsEye/releases/assets/12345"

    static func main() {
        do {
            try requestsAndCredentials()
            try assetOrigins()
            try releaseParsing()
            try rawFeedResolution()
            try statusHandling()
            print("PASS: private GitHub request headers, token validation, exact stable feed discovery, bounded metadata, trusted repository assets, credential-free raw feed resolution, and HTTP failure handling; no network or Keychain calls")
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }

    static func requestsAndCredentials() throws {
        let source = try GitHubUpdateSource(repository: repository)
        try require(source.repository == repository, "Configured repository must remain explicit")
        for bad in ["", "owner", "owner/repo/more", "/repo", "owner/", "owner/..", "owner/.",
                    "owner name/repo", "owner/repo?token=bad", "owner/repo#fragment", "owner%2Fother/repo", "owner\n/repo"] {
            try expect(.invalidRepository, "Invalid repository accepted") { _ = try GitHubUpdateSource(repository: bad) }
        }
        let testToken = "test-only-not-a-secret"
        try require(try GitHubUpdateCredentials.validatedToken("  " + testToken + "  ") == testToken, "Exterior spaces are trimmed")
        for bad in ["", "   ", "test\r\nInjected: bad", "test\n", "test\ttoken", "test token", "test\0token", "tökén", String(repeating: "x", count: 2049)] {
            try expect(.invalidToken, "Invalid token accepted") { _ = try GitHubUpdateCredentials.validatedToken(bad) }
        }
        _ = try GitHubUpdateCredentials.validatedToken(String(repeating: "x", count: 2048))
        let request = try GitHubUpdateSource.releaseRequest(repository: repository, token: testToken)
        try require(request.url?.absoluteString == "https://api.github.com/repos/calvinh99/ScholarsEye/releases/latest", "Discovery must use the private-repository releases API")
        try require(request.httpMethod == "GET" && request.httpBody == nil, "Discovery is read-only")
        try require(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + testToken, "Token is sent as an authorization header")
        try require(request.url?.query == nil, "Token must never be put into a URL")
        try require(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json", "Metadata requests use the GitHub JSON media type")
        try require(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28", "Metadata pins an API version")
        try require(request.timeoutInterval == 30 && request.cachePolicy == .reloadIgnoringLocalCacheData, "Metadata has a finite timeout and no stale cache")
    }

    static func assetOrigins() throws {
        for good in [asset, "https://api.github.com/repos/CALVINH99/scholarseye/releases/assets/12345", "https://api.github.com:443/repos/calvinh99/ScholarsEye/releases/assets/5"] {
            try require(isTrustedAssetURL(URL(string: good)!, repository: repository), "Valid repository asset was rejected")
        }
        for bad in [
            "http://api.github.com/repos/calvinh99/ScholarsEye/releases/assets/12345",
            "https://api.github.com.evil.example/repos/calvinh99/ScholarsEye/releases/assets/12345",
            "https://api.github.com/repos/other/ScholarsEye/releases/assets/12345",
            "https://api.github.com/repos/calvinh99/other/releases/assets/12345",
            "https://github.com/calvinh99/ScholarsEye/releases/download/v0.3.0/appcast.xml",
            "https://api.github.com/repos/calvinh99/ScholarsEye/releases/assets/abc",
            asset + "/more", asset + "?access=anything", asset + "#fragment",
            "https://user:password@api.github.com/repos/calvinh99/ScholarsEye/releases/assets/12345",
            "https://api.github.com:8443/repos/calvinh99/ScholarsEye/releases/assets/12345",
            "https://api.github.com/repos/calvinh99/ScholarsEye/releases/assets/%31",
            "https://api.github.com/repos/calvinh99/ScholarsEye/releases/assets/../12345",
            "https://api.github.com/repos/calvinh99/ScholarsEye/releases/assets/",
            "file:///repos/calvinh99/ScholarsEye/releases/assets/12345"
        ] {
            try require(!isTrustedAssetURL(URL(string: bad)!, repository: repository), "Untrusted asset URL was accepted")
        }
        try require(!isTrustedAssetURL(URL(string: asset)!, repository: "invalid"), "Invalid configured repository cannot become trusted")
    }

    static func payload(draft: Bool = false, prerelease: Bool = false, assets: [[String: String]]? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["draft": draft, "prerelease": prerelease,
            "assets": assets ?? [["name": "appcast.xml", "state": "uploaded", "url": asset]]])
    }

    static func releaseParsing() throws {
        let feed = try GitHubUpdateSource.feedURL(from: payload(), repository: repository)
        try require(feed.absoluteString == asset, "Exact uploaded appcast.xml is selected")
        let multiple = [["name": "ScholarsEye.zip", "state": "uploaded", "url": asset],
                        ["name": "appcast.xml", "state": "uploaded", "url": asset]]
        try require(try GitHubUpdateSource.feedURL(from: payload(assets: multiple), repository: repository) == feed, "Other assets do not replace the exact feed")
        try expect(.unpublishedRelease, "Draft cannot be offered") { _ = try GitHubUpdateSource.feedURL(from: payload(draft: true), repository: repository) }
        try expect(.unpublishedRelease, "Prerelease cannot be offered") { _ = try GitHubUpdateSource.feedURL(from: payload(prerelease: true), repository: repository) }
        for assets in [[], [["name": "Appcast.xml", "state": "uploaded", "url": asset]],
                       [["name": "appcast.xml", "state": "starter", "url": asset]],
                       Array(repeating: ["name": "appcast.xml", "state": "uploaded", "url": asset], count: 2)] {
            try expect(.missingFeed, "Missing, pending, misnamed or ambiguous feed must be explicit") {
                _ = try GitHubUpdateSource.feedURL(from: payload(assets: assets), repository: repository)
            }
        }
        try expect(.untrustedAsset, "No fallback to external browser download URLs") {
            _ = try GitHubUpdateSource.feedURL(from: payload(assets: [["name": "appcast.xml", "state": "uploaded", "url": "https://example.com/appcast.xml"]]), repository: repository)
        }
        for invalid in [Data("not JSON".utf8), Data("{\"assets\":[]}".utf8), Data("[]".utf8)] {
            try expect(.invalidResponse, "Malformed or incomplete metadata is rejected") { _ = try GitHubUpdateSource.feedURL(from: invalid, repository: repository) }
        }
        let maximum = GitHubUpdateSource.maximumResponseBytes
        var full = try payload()
        full.append(Data(repeating: 32, count: maximum - full.count))
        try require(try GitHubUpdateSource.feedURL(from: full, repository: repository) == feed, "Boundary-sized valid response is accepted")
        full.append(32)
        try expect(.responseTooLarge, "Oversized metadata is rejected before parsing") { _ = try GitHubUpdateSource.feedURL(from: full, repository: repository) }
    }

    static func statusHandling() throws {
        let url = URL(string: "https://api.github.com/repos/calvinh99/ScholarsEye/releases/latest")!
        try GitHubUpdateSource.validateResponse(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        for (code, expected) in [(401, GitHubUpdateError.unauthorized), (403, .forbidden), (404, .noRelease), (429, .rateLimited), (500, .httpStatus(500)), (302, .httpStatus(302))] {
            try expect(expected, "HTTP status has wrong recovery guidance") {
                try GitHubUpdateSource.validateResponse(HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!)
            }
        }
        for headers in [["X-RateLimit-Remaining": "0"], ["Retry-After": "60"]] {
            try expect(.rateLimited, "Rate-limited 403 should not ask for a new token") {
                try GitHubUpdateSource.validateResponse(HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: headers)!)
            }
        }
    }

    static func rawFeedResolution() throws {
        let apiURL = URL(string: asset)!
        let token = "test-only-not-a-secret"
        let request = try GitHubUpdateSource.assetRequest(url: apiURL, repository: repository, token: token)
        try require(request.value(forHTTPHeaderField: "Accept") == "application/octet-stream", "Raw feed resolution must override GitHub's JSON default")
        try require(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + token, "Only trusted API assets receive authorization")
        try expect(.untrustedAsset, "Never attach token headers to a CDN or another repository") {
            _ = try GitHubUpdateSource.assetRequest(url: URL(string: "https://example.com/asset")!, repository: repository, token: token)
        }
        let rawURL = "https://release-assets.githubusercontent.com/github-production-release-asset/123/abc?signature=test-fixture"
        let response = HTTPURLResponse(url: apiURL, statusCode: 302, httpVersion: nil, headerFields: ["Location": rawURL])!
        try require(try GitHubUpdateSource.downloadURL(from: response).absoluteString == rawURL, "Validated raw CDN URL is returned for an unauthenticated Sparkle feed request")
        for location in ["https://example.com/feed.xml?signature=test", "http://release-assets.githubusercontent.com/a?signature=test",
                         "https://release-assets.githubusercontent.com.evil.example/a?signature=test",
                         "https://token@release-assets.githubusercontent.com/a?signature=test",
                         "https://release-assets.githubusercontent.com/a?signature=test#fragment",
                         "https://release-assets.githubusercontent.com:8443/a?signature=test",
                         "https://release-assets.githubusercontent.com/a", "/relative", rawURL + "\r\n"] {
            try expect(.untrustedAsset, "Invalid feed redirect must not be followed") {
                _ = try GitHubUpdateSource.downloadURL(from: HTTPURLResponse(url: apiURL, statusCode: 302, httpVersion: nil, headerFields: ["Location": location])!)
            }
        }
        try expect(.feedRedirectUnavailable, "Direct streaming has an explicit recoverable error instead of giving Sparkle a JSON endpoint") {
            _ = try GitHubUpdateSource.downloadURL(from: HTTPURLResponse(url: apiURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        try expect(.untrustedAsset, "A redirect without a Location is rejected") {
            _ = try GitHubUpdateSource.downloadURL(from: HTTPURLResponse(url: apiURL, statusCode: 302, httpVersion: nil, headerFields: nil)!)
        }
        try expect(.unauthorized, "Asset auth failures retain useful guidance") {
            _ = try GitHubUpdateSource.downloadURL(from: HTTPURLResponse(url: apiURL, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        }
    }
}
