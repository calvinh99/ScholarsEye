import CryptoKit
import Darwin
import Foundation

struct SyncConfiguration: Codable, Equatable, Sendable {
    var host = "macmini"
    var remotePath = "~/Movies/ScholarsEye"

    func validate() throws {
        guard host.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#, options: .regularExpression) != nil else {
            throw SessionSyncError.message("Enter an SSH host or alias, such as macmini. Configure its user and key in ~/.ssh/config.")
        }
        try SessionSyncFiles.validateRemotePath(remotePath)
    }
}

struct SyncProgress: Sendable {
    enum Phase: String, Sendable { case connecting, scanning, uploading, downloading, verifying, finished }
    var phase: Phase
    var message: String
    var sessionID: String? = nil
    var completedSessions = 0
    var totalSessions = 0
}

struct SyncResult: Sendable {
    var uploaded = 0
    var downloaded = 0
    var unchanged = 0
    var conflicts: [String] = []
    var warnings: [String] = []
}

enum SessionSyncError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

struct SessionSyncFile: Codable, Equatable, Sendable {
    let name: String
    let bytes: Int64
    let sha256: String
}

struct SessionSyncEntry: Codable, Equatable, Sendable {
    let id: String
    let digest: String
    let files: [SessionSyncFile]
}

struct SessionSyncInventory: Codable, Sendable {
    let root: String
    let sessions: [SessionSyncEntry]
    let rejected: [String]
}

enum SessionSyncFiles {
    static let stagingName = ".scholarseye-sync"

    static func safeName(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,189}$"#, options: .regularExpression) != nil
    }

    static func validDigest(_ value: String) -> Bool {
        value.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil
    }

    static func validateRemotePath(_ value: String) throws {
        guard value.utf8.count <= 2_048, value.hasPrefix("/") || value.hasPrefix("~/"),
              value != "/", value != "~/", !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !value.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." }) else {
            throw SessionSyncError.message("Use an absolute remote folder or ~/Movies/ScholarsEye, without parent-directory components or control characters.")
        }
    }

    /// Arguments passed through SSH's remote shell must be quoted separately,
    /// even though the local process is launched without a shell.
    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }

    static func directory(_ url: URL, create: Bool = false) throws -> URL {
        guard url.isFileURL else { throw SessionSyncError.message("The recording library must be a local folder.") }
        guard url.path != "/" else { throw SessionSyncError.message("The recording library cannot be the filesystem root.") }
        if create { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        let root = URL(fileURLWithPath: try canonicalPath(url.path), isDirectory: true)
        guard root.path != "/" else { throw SessionSyncError.message("The recording library cannot resolve to the filesystem root.") }
        guard try FileManager.default.attributesOfItem(atPath: root.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw SessionSyncError.message("The recording library is not a directory.")
        }
        return root
    }

    static func requireRealDirectory(_ url: URL) throws {
        guard try canonicalPath(url.path) == url.path,
              try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw SessionSyncError.message("Sync does not follow linked session or staging folders.")
        }
    }

    private static func canonicalPath(_ path: String) throws -> String {
        // Foundation standardization rewrites /private/var back to the /var
        // symlink on macOS. realpath preserves the actual filesystem boundary.
        guard let result = realpath(path, nil) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { free(result) }
        return String(cString: result)
    }

    static func inventory(_ root: URL, excluding: Set<String>, checkCancellation: () throws -> Void) throws -> SessionSyncInventory {
        var sessions: [SessionSyncEntry] = [], rejected: [String] = []
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            try checkCancellation()
            let id = folder.lastPathComponent
            guard safeName(id), !excluding.contains(id),
                  (try? FileManager.default.attributesOfItem(atPath: folder.path)[.type] as? FileAttributeType) == .typeDirectory else { continue }
            let manifest = folder.appendingPathComponent("manifest.json")
            guard let data = try? readManifest(manifest),
                  let session = try? RecordingSession.decoder().decode(RecordingSession.self, from: data) else {
                rejected.append("\(id): unreadable session information")
                continue
            }
            guard session.status == "complete" else { continue }
            do { sessions.append(try entry(folder, expectedID: id, checkCancellation: checkCancellation)) }
            catch is CancellationError { throw CancellationError() }
            catch { rejected.append("\(id): \(error.localizedDescription)") }
        }
        return SessionSyncInventory(root: root.path, sessions: sessions, rejected: rejected)
    }

    static func entry(_ folder: URL, expectedID: String, checkCancellation: () throws -> Void = {}) throws -> SessionSyncEntry {
        try checkCancellation()
        guard safeName(expectedID) else { throw SessionSyncError.message("Invalid session identifier.") }
        try requireRealDirectory(folder)
        let manifest = folder.appendingPathComponent("manifest.json")
        let session = try RecordingSession.decoder().decode(RecordingSession.self, from: readManifest(manifest))
        guard session.id == expectedID, session.status == "complete", session.endedAt != nil,
              session.unfinishedFiles.isEmpty, !session.chunks.isEmpty else {
            throw SessionSyncError.message("Only complete, finalized recording sessions can sync.")
        }
        var names = Set(["manifest.json"])
        for chunk in session.chunks {
            guard safeName(chunk.fileName), chunk.fileName.hasSuffix(".mp4"), chunk.byteCount >= 0, names.insert(chunk.fileName).inserted else {
                throw SessionSyncError.message("A recording chunk has an unsafe or duplicate filename.")
            }
        }
        let diagnostics = folder.appendingPathComponent("diagnostics.json")
        var diagnosticInfo = stat()
        if lstat(diagnostics.path, &diagnosticInfo) == 0 { names.insert("diagnostics.json") }
        else if errno != ENOENT { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var files: [SessionSyncFile] = []
        for name in names.sorted() {
            let file = try hashFile(folder.appendingPathComponent(name), checkCancellation: checkCancellation)
            guard file.bytes > 0 else { throw SessionSyncError.message("A recording file is empty.") }
            if let chunk = session.chunks.first(where: { $0.fileName == name }), chunk.byteCount > 0, chunk.byteCount != file.bytes {
                throw SessionSyncError.message("A recording chunk is incomplete or changed on disk.")
            }
            files.append(file)
        }
        return SessionSyncEntry(id: expectedID, digest: digest(files), files: files)
    }

    static func digest(_ files: [SessionSyncFile]) -> String {
        let contents = files.map { "\($0.name)\0\($0.bytes)\0\($0.sha256)\n" }.joined()
        return SHA256.hash(data: Data(contents.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func validate(_ entry: SessionSyncEntry) throws {
        guard safeName(entry.id), validDigest(entry.digest), !entry.files.isEmpty,
              entry.files.map(\.name) == entry.files.map(\.name).sorted(),
              Set(entry.files.map(\.name)).count == entry.files.count,
              entry.files.contains(where: { $0.name == "manifest.json" }),
              entry.files.allSatisfy({ safeName($0.name) && $0.bytes > 0 && validDigest($0.sha256) }),
              digest(entry.files) == entry.digest else {
            throw SessionSyncError.message("The other Mac returned invalid recording information.")
        }
    }

    static func hashFile(_ url: URL, checkCancellation: () throws -> Void) throws -> SessionSyncFile {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw SessionSyncError.message("Cannot read recording file \(url.lastPathComponent); linked files are not supported.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat(), after = stat(), current = stat()
        guard fstat(descriptor, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG else {
            throw SessionSyncError.message("Recording files must be regular files.")
        }
        var hasher = SHA256()
        while true {
            try checkCancellation()
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        guard fstat(descriptor, &after) == 0, lstat(url.path, &current) == 0,
              sameFile(before, after), sameFile(after, current) else {
            throw SessionSyncError.message("A recording file changed during verification. Try syncing again after it finishes.")
        }
        return SessionSyncFile(name: url.lastPathComponent, bytes: Int64(after.st_size),
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private static func sameFile(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino && first.st_mode == second.st_mode &&
        first.st_size == second.st_size && first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec &&
        first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec && first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec &&
        first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec
    }

    static func readManifest(_ url: URL) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw SessionSyncError.message("The session manifest is missing or linked.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat(), after = stat(), current = stat()
        guard fstat(descriptor, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
              before.st_size > 0, before.st_size <= 16 * 1_024 * 1_024 else {
            throw SessionSyncError.message("The session manifest must be a regular file of a supported size.")
        }
        let data = try handle.read(upToCount: 16 * 1_024 * 1_024 + 1) ?? Data()
        guard data.count == before.st_size, fstat(descriptor, &after) == 0,
              lstat(url.path, &current) == 0, sameFile(before, after), sameFile(after, current) else {
            throw SessionSyncError.message("The session manifest changed during verification.")
        }
        return data
    }

    static func prepare(_ root: URL, entry: SessionSyncEntry) throws -> URL {
        try validate(entry)
        let staging = root.appendingPathComponent(stagingName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: staging.path) {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try requireRealDirectory(staging)
        let folder = staging.appendingPathComponent(entry.id + "-" + entry.digest, isDirectory: true)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try requireRealDirectory(folder)
        for entry in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            guard try FileManager.default.attributesOfItem(atPath: entry.path)[.type] as? FileAttributeType == .typeRegular else {
                throw SessionSyncError.message("The sync staging folder contains a linked or non-regular file.")
            }
        }
        return folder
    }

    static func finalize(_ root: URL, staging: URL, expected: SessionSyncEntry, checkCancellation: () throws -> Void = {}) throws -> Bool {
        let expectedStage = root.appendingPathComponent(stagingName).appendingPathComponent(expected.id + "-" + expected.digest)
        guard staging.standardizedFileURL.path == expectedStage.standardizedFileURL.path else {
            throw SessionSyncError.message("Invalid sync staging folder.")
        }
        let actual = try entry(staging, expectedID: expected.id, checkCancellation: checkCancellation)
        guard actual == expected else { throw SessionSyncError.message("Transferred recording files failed verification. Retry Sync to resume or repair the copy.") }
        try checkCancellation()
        let target = root.appendingPathComponent(expected.id)
        if renamex_np(staging.path, target.path, UInt32(RENAME_EXCL)) == 0 { return true }
        if errno == EEXIST {
            if let existing = try? entry(target, expectedID: expected.id, checkCancellation: checkCancellation), existing.digest == expected.digest { return false }
            throw SessionSyncError.message("Session \(expected.id) already exists with different content; neither copy was replaced.")
        }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
