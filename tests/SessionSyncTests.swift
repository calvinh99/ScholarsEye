import Darwin
import Foundation

private enum Failure: Error, LocalizedError {
    case failed(String)
    var errorDescription: String? { if case .failed(let value) = self { return value }; return nil }
}
private func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw Failure.failed(message) }
}
private func rejects(_ message: String, _ action: () throws -> Void) throws {
    do { try action() } catch { return }
    throw Failure.failed(message)
}

@main
struct SessionSyncTests {
    static let manager = FileManager.default

    static func main() async throws {
        let temporary = manager.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("ScholarsEyeSyncTests-" + UUID().uuidString)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: temporary) }
        try configurationValidation()
        try stagingAndValidation(temporary)
        try await twoWayRoundTrip(temporary)
        try await processCancellation(temporary)
        print("PASS: safe configuration/quoting; streamed fingerprints; partial/linked/FIFO rejection; resumable staging and atomic no-overwrite publication; real stock-rsync bidirectional round trip and idempotence; process-group cancellation. No SSH account or real recordings used.")
    }

    static func createSession(_ parent: URL, id: String, payload: Data = Data(repeating: 42, count: 32_768), status: String = "complete") throws -> URL {
        let folder = parent.appendingPathComponent(id)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        try payload.write(to: folder.appendingPathComponent("chunk-000001.mp4"))
        var session = RecordingSession(id: id, startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_060), status: status, configuration: CaptureConfiguration(),
            displayID: 1, displayWidth: 1920, displayHeight: 1080, url: folder)
        var chunk = RecordingChunk(id: 1, fileName: "chunk-000001.mp4", codec: .hevc, startOffsetSeconds: 0, durationSeconds: 60)
        chunk.byteCount = Int64(payload.count)
        session.chunks = [chunk]
        session.bytesWritten = Int64(payload.count)
        try session.save()
        try Data("{\"samples\": []}".utf8).write(to: folder.appendingPathComponent("diagnostics.json"))
        return folder
    }

    static func configurationValidation() throws {
        try SyncConfiguration().validate()
        try SyncConfiguration(host: "mac-mini.local", remotePath: "/Users/Learning's Mac/Recordings").validate()
        for host in ["", "-oProxyCommand=bad", "name;touch bad", "name\nother", "user@host"] {
            try rejects("Unsafe SSH alias accepted") { try SyncConfiguration(host: host).validate() }
        }
        for path in ["/", "~/", "relative/path", "/a/../b", "/a/./b", "/a\nb", "/a\u{0}b"] {
            try rejects("Unsafe remote path accepted") { try SyncConfiguration(remotePath: path).validate() }
        }
        try rejects("An aliased filesystem root was accepted as a library") {
            _ = try SessionSyncFiles.directory(URL(fileURLWithPath: "/."))
        }
        let value = "A folder's $(touch unwanted); name"
        let runner = SessionSyncProcess()
        let result = try runner.run(executable: "/bin/sh", arguments: ["-c", "printf '%s' " + SessionSyncFiles.shellQuote(value)])
        try require(result.code == 0 && String(decoding: result.output, as: UTF8.self) == value, "Remote-shell arguments preserve literal metacharacters")
    }

    static func stagingAndValidation(_ temporary: URL) throws {
        let source = try SessionSyncFiles.directory(temporary.appendingPathComponent("source"), create: true)
        let destination = try SessionSyncFiles.directory(temporary.appendingPathComponent("destination"), create: true)
        let folder = try createSession(source, id: "fixture")
        let entry = try SessionSyncFiles.entry(folder, expectedID: "fixture")
        try Data("analysis revision one".utf8).write(to: folder.appendingPathComponent("analysis.json"))
        let withAnalysis = try SessionSyncFiles.entry(folder, expectedID: "fixture")
        try require(entry == withAnalysis, "Derived analysis never changes recording identity")
        let stage = try SessionSyncFiles.prepare(destination, entry: entry)
        try require(stage.path.contains("/.scholarseye-sync/"), "Incomplete transfers remain hidden")
        try Data([1, 2, 3]).write(to: stage.appendingPathComponent("chunk-000001.mp4"))
        try rejects("Incomplete staging was published") { _ = try SessionSyncFiles.finalize(destination, staging: stage, expected: entry) }
        try require(!manager.fileExists(atPath: destination.appendingPathComponent(entry.id).path), "Failed validation exposes no session")
        let retry = try SessionSyncFiles.prepare(destination, entry: entry)
        try require(retry == stage, "An interrupted copy resumes in the same staging folder")
        for file in entry.files {
            try Data(contentsOf: folder.appendingPathComponent(file.name)).write(to: stage.appendingPathComponent(file.name))
        }
        let imported = try SessionSyncFiles.finalize(destination, staging: stage, expected: entry)
        try require(imported && !manager.fileExists(atPath: stage.path), "Validated staging is moved atomically into the library")
        let repeatedStage = try SessionSyncFiles.prepare(destination, entry: entry)
        for file in entry.files {
            try manager.copyItem(at: folder.appendingPathComponent(file.name), to: repeatedStage.appendingPathComponent(file.name))
        }
        let repeated = try SessionSyncFiles.finalize(destination, staging: repeatedStage, expected: entry)
        try require(!repeated, "A duplicate import never replaces the existing session")
        let existingManifest = try Data(contentsOf: destination.appendingPathComponent(entry.id).appendingPathComponent("manifest.json"))
        try Data(repeating: 43, count: 32_768).write(to: repeatedStage.appendingPathComponent("chunk-000001.mp4"))
        try rejects("Corrupt staging was accepted") { _ = try SessionSyncFiles.finalize(destination, staging: repeatedStage, expected: entry) }
        let unchangedManifest = try Data(contentsOf: destination.appendingPathComponent(entry.id).appendingPathComponent("manifest.json"))
        try require(existingManifest == unchangedManifest, "An existing library copy is never clobbered")

        let incomplete = try createSession(source, id: "incomplete", status: "recording")
        let inventory = try SessionSyncFiles.inventory(source, excluding: [], checkCancellation: {})
        try require(inventory.sessions.map(\.id) == ["fixture"], "Active recordings stay out of sync")
        let excluded = try SessionSyncFiles.inventory(source, excluding: ["fixture"], checkCancellation: {})
        try require(excluded.sessions.isEmpty, "Caller exclusions are honored")
        try manager.removeItem(at: incomplete.appendingPathComponent("manifest.json"))
        let fifo = incomplete.appendingPathComponent("manifest.json")
        try require(mkfifo(fifo.path, 0o600) == 0, "Create controlled FIFO fixture")
        try rejects("A FIFO manifest was read") { _ = try SessionSyncFiles.readManifest(fifo) }
        try rejects("A FIFO recording was hashed") { _ = try SessionSyncFiles.hashFile(fifo, checkCancellation: {}) }
        let linked = source.appendingPathComponent("linked")
        try manager.createSymbolicLink(at: linked, withDestinationURL: folder)
        try rejects("Linked sessions accepted") { _ = try SessionSyncFiles.entry(linked, expectedID: "fixture") }
        let diagnostics = folder.appendingPathComponent("diagnostics.json")
        try manager.removeItem(at: diagnostics)
        try manager.createSymbolicLink(at: diagnostics, withDestinationURL: source.appendingPathComponent("missing"))
        try rejects("Dangling diagnostic symlink was ignored") { _ = try SessionSyncFiles.entry(folder, expectedID: "fixture") }
    }

    static func twoWayRoundTrip(_ temporary: URL) async throws {
        let local = try SessionSyncFiles.directory(temporary.appendingPathComponent("Laptop recordings"), create: true)
        let remote = try SessionSyncFiles.directory(temporary.appendingPathComponent("Master's $(printf literal) recordings"), create: true)
        let localOnly = try createSession(local, id: "local-only")
        _ = try createSession(remote, id: "remote-only", payload: Data(repeating: 19, count: 48_321))
        let shared = try createSession(local, id: "shared")
        try manager.copyItem(at: shared, to: remote.appendingPathComponent("shared"))
        _ = try createSession(local, id: "conflict", payload: Data(repeating: 1, count: 4_096))
        _ = try createSession(remote, id: "conflict", payload: Data(repeating: 2, count: 4_096))
        _ = try createSession(local, id: "recording", status: "recording")
        _ = try createSession(remote, id: "excluded")
        try Data("local report".utf8).write(to: localOnly.appendingPathComponent("analysis.json"))

        // Behaves like SSH's remote command transport while keeping both ends
        // inside this isolated fixture. rsync itself is the real macOS binary.
        let fakeSSH = temporary.appendingPathComponent("fake ssh")
        let script = #"""
#!/usr/bin/python3
import os, sys
args = sys.argv[1:]
while args and args[0].startswith('-'):
    option = args.pop(0)
    if option in ('-o', '-l', '-p'):
        args.pop(0)
if not args or args.pop(0) != 'fixture':
    raise SystemExit('unexpected fixture host')
os.execv('/bin/sh', ['sh', '-c', ' '.join(args)])
"""#
        try Data(script.utf8).write(to: fakeSSH)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeSSH.path)
        let configuration = SyncConfiguration(host: "fixture", remotePath: remote.path)
        let service = SessionSyncService(sshExecutable: fakeSSH.path)
        let result = try await service.sync(localRoot: local, configuration: configuration, excludingSessionIDs: ["excluded"])
        try require(result.uploaded == 1 && result.downloaded == 1 && result.unchanged == 1 && result.conflicts == ["conflict"], "Bidirectional planning copies missing sessions, skips matches, and preserves conflicts")
        let localInventory = try SessionSyncFiles.inventory(local, excluding: [], checkCancellation: {})
        let remoteInventory = try SessionSyncFiles.inventory(remote, excluding: ["excluded"], checkCancellation: {})
        for id in ["local-only", "remote-only", "shared"] {
            try require(localInventory.sessions.first { $0.id == id } == remoteInventory.sessions.first { $0.id == id }, "Every original file and track stays byte-identical after sync")
        }
        try require(!manager.fileExists(atPath: remote.appendingPathComponent("local-only/analysis.json").path), "Generated reports are not synchronized")
        try require(!manager.fileExists(atPath: remote.appendingPathComponent("recording").path), "The master never receives active recordings")
        try require(!manager.fileExists(atPath: local.appendingPathComponent("excluded").path), "Excluded remote IDs are not downloaded")
        try Data("changed local report".utf8).write(to: localOnly.appendingPathComponent("analysis.json"))
        let second = try await service.sync(localRoot: local, configuration: configuration, excludingSessionIDs: ["excluded"])
        try require(second.uploaded == 0 && second.downloaded == 0 && second.unchanged == 3 && second.conflicts == ["conflict"], "Repeating sync is idempotent even after analysis changes")

        // Simulate interruption after a partial regular file arrives remotely.
        let resumable = try createSession(local, id: "resume", payload: Data(repeating: 91, count: 83_211))
        let expected = try SessionSyncFiles.entry(resumable, expectedID: "resume")
        let stage = try SessionSyncFiles.prepare(remote, entry: expected)
        try Data(repeating: 91, count: 73).write(to: stage.appendingPathComponent("chunk-000001.mp4"))
        let resumed = try await service.sync(localRoot: local, configuration: configuration, excludingSessionIDs: ["excluded"])
        try require(resumed.uploaded == 1, "Real stock rsync repairs and resumes a partial staged payload")
        let copied = try SessionSyncFiles.entry(remote.appendingPathComponent("resume"), expectedID: "resume")
        try require(copied == expected, "The resumed payload is validated before publication")
    }

    static func processCancellation(_ temporary: URL) async throws {
        let childFile = temporary.appendingPathComponent("child.pid")
        let runner = SessionSyncProcess()
        let task = Task.detached {
            try runner.run(executable: "/bin/sh", arguments: ["-c", "sleep 60 & echo $! > " + SessionSyncFiles.shellQuote(childFile.path) + "; wait"])
        }
        for _ in 0..<300 {
            if manager.fileExists(atPath: childFile.path) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let child = Int32(try String(contentsOf: childFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        runner.cancel()
        do { _ = try await task.value; throw Failure.failed("Cancellation returned success") }
        catch is CancellationError { }
        for _ in 0..<100 {
            if kill(child, 0) != 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try require(kill(child, 0) != 0, "Cancellation terminates the child process as well as its parent")
        let cancelledBeforeStart = SessionSyncProcess()
        cancelledBeforeStart.cancel()
        do {
            _ = try cancelledBeforeStart.run(executable: "/bin/sleep", arguments: ["60"])
            throw Failure.failed("An already-cancelled process launched")
        } catch is CancellationError { }
    }
}
