import Foundation
import Security

enum GitHubUpdateError: LocalizedError, Equatable {
    case invalidRepository, invalidToken, invalidResponse, responseTooLarge
    case unauthorized, forbidden, rateLimited, noRelease, unpublishedRelease, missingFeed, untrustedAsset, feedRedirectUnavailable
    case httpStatus(Int), keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidRepository: return "The update repository must use owner/repository format."
        case .invalidToken: return "Enter a valid GitHub access token without spaces or control characters."
        case .invalidResponse: return "GitHub returned an unexpected release response. Try checking again."
        case .responseTooLarge: return "GitHub's release response exceeded the update metadata limit."
        case .unauthorized: return "GitHub rejected this access token. Replace it with a valid token."
        case .forbidden: return "GitHub denied access. Give this token Contents: read access to the ScholarsEye repository."
        case .rateLimited: return "GitHub's request limit was reached. Wait a while before checking again."
        case .noRelease: return "No published release is available, or this token cannot access the repository."
        case .unpublishedRelease: return "The latest release is a draft or prerelease. It is not offered as a stable update."
        case .missingFeed: return "The latest release does not have a finished appcast.xml update asset."
        case .untrustedAsset: return "The update asset does not belong to the configured GitHub repository."
        case .feedRedirectUnavailable: return "GitHub did not provide a temporary download link for the update feed. Try checking again later."
        case .httpStatus(let code): return "GitHub returned HTTP \(code). Try checking again later."
        case .keychain(let status):
            // A numeric status is useful for recovery without exposing the token.
            return "ScholarsEye couldn't access its update credential in Keychain (\(status))."
        }
    }
}

/// Discovers only a published, stable feed asset in the configured private repo.
/// Sparkle separately verifies the feed and archive with the embedded public key.
struct GitHubUpdateSource: Sendable {
    static let maximumResponseBytes = 1_048_576
    let repository: String

    init(repository: String) throws {
        self.repository = try Self.validatedRepository(repository)
    }

    func latestFeed(token: String) async throws -> URL {
        let request = try Self.releaseRequest(repository: repository, token: token)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        // This metadata endpoint has no expected redirect. Reject redirects so
        // credentials never follow a moved endpoint to an untrusted destination.
        let session = URLSession(configuration: configuration, delegate: GitHubMetadataSessionDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw GitHubUpdateError.invalidResponse }
        try Self.validateResponse(http)
        if response.expectedContentLength > Int64(Self.maximumResponseBytes) {
            throw GitHubUpdateError.responseTooLarge
        }
        var body = Data()
        body.reserveCapacity(min(Int(max(response.expectedContentLength, 0)), Self.maximumResponseBytes))
        for try await byte in bytes {
            guard body.count < Self.maximumResponseBytes else { throw GitHubUpdateError.responseTooLarge }
            body.append(byte)
        }
        let assetURL = try Self.feedURL(from: body, repository: repository)
        // Sparkle overrides Accept for appcast requests. Ask GitHub for the
        // temporary raw-content URL first, without forwarding our credential.
        let assetRequest = try Self.assetRequest(url: assetURL, repository: repository, token: token)
        let (_, assetResponse) = try await session.bytes(for: assetRequest)
        guard let assetHTTP = assetResponse as? HTTPURLResponse else { throw GitHubUpdateError.invalidResponse }
        return try Self.downloadURL(from: assetHTTP)
    }

    static func releaseRequest(repository: String, token: String) throws -> URLRequest {
        let repository = try validatedRepository(repository)
        let token = try GitHubUpdateCredentials.validatedToken(token)
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            throw GitHubUpdateError.invalidRepository
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("ScholarsEye-Updater", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func archiveRequestHeaders(token: String) throws -> [String: String] {
        ["Authorization": "Bearer \(try GitHubUpdateCredentials.validatedToken(token))",
         "Accept": "application/octet-stream", "X-GitHub-Api-Version": "2022-11-28"]
    }

    static func assetRequest(url: URL, repository: String, token: String) throws -> URLRequest {
        guard isTrustedAssetURL(url, repository: repository) else { throw GitHubUpdateError.untrustedAsset }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.allHTTPHeaderFields = try archiveRequestHeaders(token: token)
        request.setValue("ScholarsEye-Updater", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func downloadURL(from response: HTTPURLResponse) throws -> URL {
        guard response.statusCode == 302 else {
            if response.statusCode == 200 { throw GitHubUpdateError.feedRedirectUnavailable }
            try validateResponse(response)
            throw GitHubUpdateError.feedRedirectUnavailable
        }
        guard let location = response.value(forHTTPHeaderField: "Location"), location.utf8.count <= 16_384,
              !location.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let url = URL(string: location), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", parts.host?.lowercased() == "release-assets.githubusercontent.com",
              parts.port == nil || parts.port == 443,
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              !parts.path.isEmpty, parts.path != "/", parts.query?.isEmpty == false else {
            throw GitHubUpdateError.untrustedAsset
        }
        return url
    }

    static func validateResponse(_ response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200: return
        case 401: throw GitHubUpdateError.unauthorized
        case 403:
            if response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0"
                || response.value(forHTTPHeaderField: "Retry-After") != nil {
                throw GitHubUpdateError.rateLimited
            }
            throw GitHubUpdateError.forbidden
        case 404: throw GitHubUpdateError.noRelease
        case 429: throw GitHubUpdateError.rateLimited
        default: throw GitHubUpdateError.httpStatus(response.statusCode)
        }
    }

    static func feedURL(from data: Data, repository: String) throws -> URL {
        _ = try validatedRepository(repository)
        guard data.count <= maximumResponseBytes else { throw GitHubUpdateError.responseTooLarge }
        struct Release: Decodable {
            struct Asset: Decodable { let name: String; let state: String; let url: String }
            let draft: Bool
            let prerelease: Bool
            let assets: [Asset]
        }
        let release: Release
        do { release = try JSONDecoder().decode(Release.self, from: data) }
        catch { throw GitHubUpdateError.invalidResponse }
        guard !release.draft && !release.prerelease else { throw GitHubUpdateError.unpublishedRelease }
        let candidates = release.assets.filter { $0.name == "appcast.xml" }
        guard candidates.count == 1, let asset = candidates.first, asset.state == "uploaded" else {
            throw GitHubUpdateError.missingFeed
        }
        guard let url = URL(string: asset.url), isTrustedAssetURL(url, repository: repository) else {
            throw GitHubUpdateError.untrustedAsset
        }
        return url
    }

    static func validatedRepository(_ repository: String) throws -> String {
        let pieces = repository.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 2, pieces[0].count <= 100, pieces[1].count <= 100,
              pieces[0].range(of: "^[A-Za-z0-9][A-Za-z0-9-]*$", options: .regularExpression) != nil,
              pieces[1].range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil,
              pieces[1] != ".", pieces[1] != ".." else { throw GitHubUpdateError.invalidRepository }
        return repository
    }
}

/// Authorization headers may only target API assets in the selected repository.
func isTrustedAssetURL(_ url: URL, repository: String) -> Bool {
    guard (try? GitHubUpdateSource.validatedRepository(repository)) != nil,
          let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
          parts.scheme?.lowercased() == "https", parts.host?.lowercased() == "api.github.com",
          parts.port == nil || parts.port == 443,
          parts.user == nil, parts.password == nil, parts.fragment == nil, parts.query == nil else { return false }
    let expectedPrefix = "/repos/\(repository)/releases/assets/".lowercased()
    let path = parts.percentEncodedPath.lowercased()
    guard path.hasPrefix(expectedPrefix) else { return false }
    let identifier = path.dropFirst(expectedPrefix.count)
    return !identifier.isEmpty && identifier.allSatisfy { $0 >= "0" && $0 <= "9" }
}

private final class GitHubMetadataSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum GitHubUpdateCredentials {
    static func validatedToken(_ token: String) throws -> String {
        // Reject embedded/newline header injection before trimming exterior spaces.
        guard !token.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw GitHubUpdateError.invalidToken
        }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 2048,
              trimmed.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 }) else {
            throw GitHubUpdateError.invalidToken
        }
        return trimmed
    }

    static func read(repository: String) throws -> String? {
        var query = try baseQuery(repository: repository)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw GitHubUpdateError.keychain(status) }
        guard let data = value as? Data, let token = String(data: data, encoding: .utf8) else {
            throw GitHubUpdateError.invalidToken
        }
        return try validatedToken(token)
    }

    static func save(token: String, repository: String) throws {
        let token = try validatedToken(token)
        let query = try baseQuery(repository: repository)
        let updates: [String: Any] = [kSecValueData as String: Data(token.utf8),
                                      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if status == errSecItemNotFound {
            let attributes = query.merging(updates) { _, new in new }
            let added = SecItemAdd(attributes as CFDictionary, nil)
            guard added == errSecSuccess else { throw GitHubUpdateError.keychain(added) }
        } else if status != errSecSuccess {
            throw GitHubUpdateError.keychain(status)
        }
    }

    static func remove(repository: String) throws {
        let status = SecItemDelete(try baseQuery(repository: repository) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GitHubUpdateError.keychain(status)
        }
    }

    private static func baseQuery(repository: String) throws -> [String: Any] {
        let repository = try GitHubUpdateSource.validatedRepository(repository)
        let service = (Bundle.main.bundleIdentifier ?? "com.scholarseye.app") + ".github-updates"
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: repository,
                kSecAttrSynchronizable as String: false]
    }
}
