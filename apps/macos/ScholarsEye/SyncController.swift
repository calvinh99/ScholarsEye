import Foundation
import Combine

/// Owns one manual sync across every window, including its child processes.
@MainActor
final class SyncController: ObservableObject {
    @Published var host: String {
        didSet { if host != oldValue { defaults.set(host, forKey: "sync.host"); configurationChanged() } }
    }
    @Published var remotePath: String {
        didSet { if remotePath != oldValue { defaults.set(remotePath, forKey: "sync.remotePath"); configurationChanged() } }
    }
    @Published private(set) var isSyncing = false
    @Published private(set) var status = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var progressFraction: Double?

    private let recorder: CaptureController
    private let defaults: UserDefaults
    private var job: Task<Void, Never>?
    private var service: SessionSyncService?
    private var runID: UUID?
    private var cancelling = false
    // Installed by the app alongside the updater's reciprocal sync guard.
    var updateIsInProgress: () -> Bool = { true }

    init(recorder: CaptureController, defaults: UserDefaults = .standard) {
        self.recorder = recorder
        self.defaults = defaults
        host = defaults.string(forKey: "sync.host") ?? ""
        remotePath = defaults.string(forKey: "sync.remotePath") ?? "~/Movies/ScholarsEye"
        lastSyncAt = defaults.object(forKey: "sync.lastCompletedAt") as? Date
    }

    private func configurationChanged() {
        lastSyncAt = nil
        defaults.removeObject(forKey: "sync.lastCompletedAt")
        if !isSyncing { status = ""; errorMessage = nil; progressFraction = nil }
    }

    func start() {
        guard !isSyncing, !updateIsInProgress() else { return }
        let configuration = SyncConfiguration(host: host.trimmingCharacters(in: .whitespacesAndNewlines),
                                              remotePath: remotePath.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !configuration.host.isEmpty, !configuration.remotePath.isEmpty else {
            errorMessage = "Enter the master's SSH host and recordings folder."
            return
        }
        guard recorder.beginSessionSync() else {
            errorMessage = "Finish recording and checking media before syncing."
            return
        }
        let service = SessionSyncService()
        let id = UUID()
        self.service = service
        runID = id
        isSyncing = true
        cancelling = false
        status = "Connecting…"
        errorMessage = nil
        progressFraction = nil
        job = Task { [self] in
            defer {
                recorder.refreshSessions()
                recorder.endSessionSync()
                isSyncing = false
                progressFraction = nil
                self.service = nil
                job = nil
                runID = nil
            }
            do {
                let result = try await service.sync(localRoot: recorder.storageURL,
                    configuration: configuration, excludingSessionIDs: []) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.runID == id, self.isSyncing, !self.cancelling else { return }
                        self.status = progress.message
                        self.progressFraction = progress.totalSessions > 0
                            ? Double(progress.completedSessions) / Double(progress.totalSessions) : nil
                    }
                }
                try Task.checkCancellation()
                if result.uploaded == 0 && result.downloaded == 0 {
                    status = result.conflicts.isEmpty && result.warnings.isEmpty
                        ? "All sessions are up to date." : "No sessions copied."
                } else {
                    status = "\(result.uploaded) uploaded · \(result.downloaded) downloaded"
                }
                if result.conflicts.isEmpty && result.warnings.isEmpty {
                    let date = Date()
                    lastSyncAt = date
                    defaults.set(date, forKey: "sync.lastCompletedAt")
                }
                var notices: [String] = []
                if !result.conflicts.isEmpty {
                    notices.append("\(result.conflicts.count) session(s) differ between Macs and were left unchanged: "
                        + result.conflicts.prefix(3).joined(separator: ", "))
                }
                if !result.warnings.isEmpty {
                    notices.append("Some sessions could not be synced: " + result.warnings.prefix(3).joined(separator: "; "))
                }
                errorMessage = notices.isEmpty ? nil : notices.joined(separator: "\n")
            } catch {
                if cancelling || error is CancellationError || Task.isCancelled {
                    status = "Sync cancelled. Click Sync now to resume."
                } else {
                    status = ""
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    func cancel() {
        guard isSyncing, !cancelling else { return }
        cancelling = true
        status = "Cancelling…"
        // Capture this run's service so a late cancellation cannot affect a retry.
        let pending = job
        let activeService = service
        pending?.cancel()
        Task {
            await activeService?.cancel()
            await pending?.value
        }
    }

    func cancelAndWait() async {
        guard isSyncing else { return }
        cancelling = true
        status = "Cancelling…"
        let pending = job
        let activeService = service
        pending?.cancel()
        await activeService?.cancel()
        await pending?.value
    }
}
