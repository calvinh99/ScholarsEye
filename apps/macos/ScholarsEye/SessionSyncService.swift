import Foundation

actor SessionSyncService {
    private let sshExecutable: String
    private let rsyncExecutable: String
    private var running = false
    private var cancellation: SessionSyncCancellation?
    private var process: SessionSyncProcess?
    private var processTask: Task<SessionSyncProcessResult, Error>?

    static let sshOptions = ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
                             "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2",
                             "-o", "StrictHostKeyChecking=accept-new"]

    init(sshExecutable: String = "/usr/bin/ssh", rsyncExecutable: String = "/usr/bin/rsync") {
        self.sshExecutable = sshExecutable
        self.rsyncExecutable = rsyncExecutable
    }

    func sync(localRoot: URL, configuration: SyncConfiguration, excludingSessionIDs: Set<String> = [],
              progress: @escaping @Sendable (SyncProgress) -> Void = { _ in }) async throws -> SyncResult {
        guard !running else { throw SessionSyncError.message("A sync is already running.") }
        try configuration.validate()
        try Task.checkCancellation()
        let token = SessionSyncCancellation()
        cancellation = token
        running = true
        defer { running = false; cancellation = nil; process = nil; processTask = nil }
        return try await withTaskCancellationHandler(operation: {
            try await perform(localRoot: localRoot, configuration: configuration, excluding: excludingSessionIDs,
                              token: token, progress: progress)
        }, onCancel: {
            token.cancel()
            Task { await self.cancel() }
        })
    }

    /// The caller may additionally await its sync task for final completion of
    /// any hash verification that was in flight when cancellation arrived.
    func cancel() async {
        cancellation?.cancel()
        process?.cancel()
        if let processTask { _ = await processTask.result }
    }

    private func perform(localRoot: URL, configuration: SyncConfiguration, excluding: Set<String>,
                         token: SessionSyncCancellation,
                         progress: @escaping @Sendable (SyncProgress) -> Void) async throws -> SyncResult {
        let root = try SessionSyncFiles.directory(localRoot, create: true)
        progress(SyncProgress(phase: .connecting, message: "Connecting to \(configuration.host)…"))
        let remote: SessionSyncInventory = try await remoteCommand("inventory", configuration: configuration, token: token)
        try SessionSyncFiles.validateRemotePath(remote.root)
        guard remote.root.hasPrefix("/"), Set(remote.sessions.map(\.id)).count == remote.sessions.count else {
            throw SessionSyncError.message("The other Mac returned an invalid session library.")
        }
        for entry in remote.sessions { try SessionSyncFiles.validate(entry) }
        progress(SyncProgress(phase: .scanning, message: "Checking completed recordings…"))
        let local = try await Task.detached(priority: .utility) {
            try SessionSyncFiles.inventory(root, excluding: excluding, checkCancellation: token.check)
        }.value
        try token.check()
        let localEntries = Dictionary(uniqueKeysWithValues: local.sessions.map { ($0.id, $0) })
        let remoteEntries = Dictionary(uniqueKeysWithValues: remote.sessions.filter { !excluding.contains($0.id) }.map { ($0.id, $0) })
        let identifiers = Set(localEntries.keys).union(remoteEntries.keys).sorted()
        var result = SyncResult()
        result.warnings = local.rejected + remote.rejected
        var completed = 0
        for identifier in identifiers {
            try token.check()
            let localEntry = localEntries[identifier], remoteEntry = remoteEntries[identifier]
            if let localEntry, let remoteEntry {
                if localEntry.digest == remoteEntry.digest { result.unchanged += 1 }
                else { result.conflicts.append(identifier) }
            } else if let entry = localEntry {
                progress(SyncProgress(phase: .uploading, message: "Sending recording to \(configuration.host)…", sessionID: identifier,
                    completedSessions: completed, totalSessions: identifiers.count))
                let prepared: Prepared = try await remoteCommand("prepare", configuration: configuration, entry: entry, token: token)
                let expectedPath = URL(fileURLWithPath: remote.root).appendingPathComponent(SessionSyncFiles.stagingName)
                    .appendingPathComponent(entry.id + "-" + entry.digest).path
                guard prepared.path == expectedPath else { throw SessionSyncError.message("The other Mac returned an unsafe staging location.") }
                try await transfer(entry, upload: true, localFolder: root.appendingPathComponent(identifier),
                    remoteFolder: prepared.path, configuration: configuration, token: token)
                progress(SyncProgress(phase: .verifying, message: "Verifying uploaded recording…", sessionID: identifier,
                    completedSessions: completed, totalSessions: identifiers.count))
                let finalized: Finalized = try await remoteCommand("finalize", configuration: configuration, entry: entry, token: token)
                guard ["imported", "unchanged"].contains(finalized.status) else { throw SessionSyncError.message("The other Mac could not finalize the recording.") }
                if finalized.status == "imported" { result.uploaded += 1 } else { result.unchanged += 1 }
            } else if let entry = remoteEntry {
                let staging = try SessionSyncFiles.prepare(root, entry: entry)
                progress(SyncProgress(phase: .downloading, message: "Receiving recording from \(configuration.host)…", sessionID: identifier,
                    completedSessions: completed, totalSessions: identifiers.count))
                try await transfer(entry, upload: false, localFolder: staging,
                    remoteFolder: URL(fileURLWithPath: remote.root).appendingPathComponent(identifier).path,
                    configuration: configuration, token: token)
                progress(SyncProgress(phase: .verifying, message: "Verifying downloaded recording…", sessionID: identifier,
                    completedSessions: completed, totalSessions: identifiers.count))
                let imported = try await Task.detached(priority: .utility) {
                    try SessionSyncFiles.finalize(root, staging: staging, expected: entry, checkCancellation: token.check)
                }.value
                if imported { result.downloaded += 1 } else { result.unchanged += 1 }
            }
            completed += 1
        }
        try token.check()
        progress(SyncProgress(phase: .finished, message: "Sync complete", completedSessions: completed, totalSessions: identifiers.count))
        return result
    }

    private struct Prepared: Decodable { let path: String }
    private struct Finalized: Decodable { let status: String }

    private func remoteCommand<Response: Decodable>(_ action: String, configuration: SyncConfiguration,
                                                    entry: SessionSyncEntry? = nil, token: SessionSyncCancellation) async throws -> Response {
        let remoteArguments = ["/usr/bin/python3", "-", action, configuration.remotePath] + (entry.map { [$0.id, $0.digest] } ?? [])
        let command = remoteArguments.map(SessionSyncFiles.shellQuote).joined(separator: " ")
        let output = try await run(sshExecutable, arguments: Self.sshOptions + [configuration.host, command],
                                   input: Data(SessionSyncRemoteHelper.python.utf8), token: token)
        do { return try JSONDecoder().decode(Response.self, from: output) }
        catch { throw SessionSyncError.message("The other Mac returned an unreadable sync response. Its SSH login must not print extra text for noninteractive commands.") }
    }

    private func transfer(_ entry: SessionSyncEntry, upload: Bool, localFolder: URL, remoteFolder: String,
                          configuration: SyncConfiguration, token: SessionSyncCancellation) async throws {
        try token.check()
        let list = FileManager.default.temporaryDirectory.appendingPathComponent("ScholarsEyeSyncFiles-" + UUID().uuidString)
        try Data((entry.files.map(\.name).joined(separator: "\n") + "\n").utf8).write(to: list, options: .atomic)
        defer { try? FileManager.default.removeItem(at: list) }
        let remote = configuration.host + ":" + SessionSyncFiles.shellQuote(remoteFolder + "/")
        let local = localFolder.path + "/"
        let shell = ([sshExecutable] + Self.sshOptions).map(SessionSyncFiles.shellQuote).joined(separator: " ")
        let arguments = ["-r", "-t", "--checksum", "--partial", "--timeout=60",
                         "--files-from=" + list.path, "--rsync-path=/usr/bin/rsync", "-e", shell, "--"] +
            (upload ? [local, remote] : [remote, local])
        _ = try await run(rsyncExecutable, arguments: arguments, token: token)
    }

    private func run(_ executable: String, arguments: [String], input: Data = Data(), token: SessionSyncCancellation) async throws -> Data {
        try token.check()
        let process = SessionSyncProcess()
        self.process = process
        let task = Task.detached(priority: .utility) { try process.run(executable: executable, arguments: arguments, input: input) }
        processTask = task
        defer { self.process = nil; processTask = nil }
        let result = try await task.value
        try token.check()
        guard result.code == 0 else {
            let detail = result.error.isEmpty ? "The transfer process exited with code \(result.code)." : result.error
            throw SessionSyncError.message("Sync failed. \(detail) Check the SSH alias, access key, host key, and remote folder. The master Mac needs /usr/bin/python3 and /usr/bin/rsync.")
        }
        return result.output
    }
}
