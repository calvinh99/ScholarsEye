import Darwin
import Foundation

final class SessionSyncCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
}

struct SessionSyncProcessResult: Sendable {
    let code: Int32
    let output: Data
    let error: String
}

/// Each invocation owns a process group, so cancelling rsync also terminates
/// the SSH child it starts. No shell is used for local argument execution.
final class SessionSyncProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var processID: pid_t = 0
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        let identifier = processID
        if identifier > 0 { _ = kill(-identifier, SIGTERM) }
        lock.unlock()
        guard identifier > 0 else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if self.processID == identifier { _ = kill(-identifier, SIGKILL) }
            self.lock.unlock()
        }
    }

    func run(executable: String, arguments: [String], input: Data = Data()) throws -> SessionSyncProcessResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw SessionSyncError.message("Required tool is unavailable: \(executable).")
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ScholarsEyeSyncProcess-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let inputURL = scratch.appendingPathComponent("input")
        try input.write(to: inputURL)
        let outputURL = scratch.appendingPathComponent("output"), errorURL = scratch.appendingPathComponent("error")
        let inputFD = open(inputURL.path, O_RDONLY | O_CLOEXEC)
        let outputFD = open(outputURL.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        let errorFD = open(errorURL.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        defer { for descriptor in [inputFD, outputFD, errorFD] where descriptor >= 0 { close(descriptor) } }
        guard inputFD >= 0, outputFD >= 0, errorFD >= 0 else { throw POSIXError(.EIO) }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0, posix_spawnattr_init(&attributes) == 0 else { throw POSIXError(.ENOMEM) }
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        for (source, destination) in [(inputFD, STDIN_FILENO), (outputFD, STDOUT_FILENO), (errorFD, STDERR_FILENO)] {
            guard posix_spawn_file_actions_adddup2(&actions, source, destination) == 0 else { throw POSIXError(.EBADF) }
        }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        let command = ([executable] + arguments).map { strdup($0) } + [nil]
        let environment = ProcessInfo.processInfo.environment.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { command.forEach { free($0) }; environment.forEach { free($0) } }
        var identifier: pid_t = 0
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        let code = command.withUnsafeBufferPointer { commandPointer in
            environment.withUnsafeBufferPointer { environmentPointer in
                posix_spawn(&identifier, executable, &actions, &attributes,
                    UnsafeMutablePointer(mutating: commandPointer.baseAddress!),
                    UnsafeMutablePointer(mutating: environmentPointer.baseAddress!))
            }
        }
        if code == 0 { processID = identifier }
        lock.unlock()
        guard code == 0 else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }

        var status: Int32 = 0
        var waited: pid_t
        repeat { waited = waitpid(identifier, &status, 0) } while waited < 0 && errno == EINTR
        lock.lock()
        let wasCancelled = cancelled
        if wasCancelled { _ = kill(-identifier, SIGKILL) }
        processID = 0
        lock.unlock()
        if wasCancelled { throw CancellationError() }
        guard waited == identifier else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECHILD) }
        let outputHandle = try FileHandle(forReadingFrom: outputURL)
        defer { try? outputHandle.close() }
        let output = try outputHandle.read(upToCount: 16 * 1_024 * 1_024 + 1) ?? Data()
        guard output.count <= 16 * 1_024 * 1_024 else { throw SessionSyncError.message("The sync response exceeded the supported size.") }
        let errorHandle = try FileHandle(forReadingFrom: errorURL)
        defer { try? errorHandle.close() }
        let errorData = try errorHandle.read(upToCount: 8_192) ?? Data()
        let errorText = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let exitCode: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return SessionSyncProcessResult(code: exitCode, output: output, error: errorText)
    }
}
