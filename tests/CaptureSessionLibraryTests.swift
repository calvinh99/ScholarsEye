import Foundation

private enum Failure: Error { case failed(String) }
private func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw Failure.failed(message) }
}

@main
struct CaptureSessionLibraryTests {
    @MainActor
    static func main() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("ScholarsEyeLibraryController-" + UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        for id in ["one", "two"] {
            let folder = root.appendingPathComponent(id)
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            let session = RecordingSession(id: id, startedAt: Date(), status: "complete",
                configuration: CaptureConfiguration(), displayID: 1, displayWidth: 640, displayHeight: 360, url: folder)
            try session.save()
        }
        var discoveryCalls = 0
        let discovery = CaptureDisplayDiscovery(hasScreenAccess: { false }, load: {
            discoveryCalls += 1
            return CaptureDisplaySnapshot(sources: [], displays: [])
        }, mainDisplayID: { nil }, localDisplays: { [] })
        let controller = CaptureController(storageURL: root, displayDiscovery: discovery)
        let one = controller.sessions.first { $0.id == "one" }!
        let two = controller.sessions.first { $0.id == "two" }!
        let manifestURL = one.url.appendingPathComponent("manifest.json")
        let before = try Data(contentsOf: manifestURL)
        var published: [Set<String>] = []
        let observation = controller.$analyzingSessionIDs.sink { published.append($0) }
        defer { observation.cancel() }

        var wrongPath = one
        wrongPath.url = root.appendingPathComponent("not-one")
        try require(!controller.beginSessionAnalysis(wrongPath), "A matching ID at another path must not start analysis")
        try require(controller.analyzingSessionIDs.isEmpty, "Rejected analysis leaves the shared state untouched")
        try require(controller.beginSessionAnalysis(one), "A current library session acquires the shared analysis lock")
        try require(!controller.beginSessionAnalysis(one), "Another view cannot launch duplicate analysis")
        try require(controller.beginSessionAnalysis(two), "Independent sessions can analyze concurrently")
        try require(!controller.beginSessionSync() && !controller.syncInProgress,
                    "Sync cannot inventory files while any analysis owns a library session")
        controller.refreshSessions()
        try require(controller.analyzingSessionIDs == ["one", "two"], "Refreshing or reopening a view preserves running analysis locks")
        do {
            try controller.trashSession(one)
            throw Failure.failed("Controller allowed Trash during analysis")
        } catch let error as SessionLibraryError {
            try require(error == .analysisInProgress, "Analysis blocks Trash before any filesystem operation")
        }
        let afterBlockedTrash = try Data(contentsOf: manifestURL)
        try require(afterBlockedTrash == before, "Trash protection preserves the active analysis input")
        controller.endSessionAnalysis("one")
        try require(controller.analyzingSessionIDs == ["two"], "Finishing one analysis does not release another session's lock")
        try require(controller.beginSessionAnalysis(one), "A finished analysis may be retried")
        controller.endSessionAnalysis("one")
        controller.endSessionAnalysis("two")
        controller.endSessionAnalysis("unknown")
        try require(controller.analyzingSessionIDs.isEmpty, "Ending an unknown or completed analysis is harmless")
        try require(published.contains(["one", "two"]) && published.last?.isEmpty == true,
                    "Shared lock changes publish to every observing window")

        var syncPublished: [Bool] = []
        let syncObservation = controller.$syncInProgress.sink { syncPublished.append($0) }
        defer { syncObservation.cancel() }
        try require(controller.beginSessionSync(), "An idle library with finished analyses can acquire the sync lock")
        try require(controller.syncInProgress, "The lock is shared by every window")
        try require(!controller.beginSessionSync(), "A second sync cannot acquire the same library")
        try require(!controller.beginSessionAnalysis(one) && controller.analyzingSessionIDs.isEmpty,
                    "No new analysis can write into a syncing library")
        do {
            try controller.trashSession(one)
            throw Failure.failed("Controller allowed Trash during sync")
        } catch let error as SessionLibraryError {
            try require(error == .syncInProgress, "Sync blocks Trash before any filesystem operation")
        }
        var captureConfiguration = CaptureConfiguration()
        captureConfiguration.recordMicrophone = false
        await controller.start(configuration: captureConfiguration)
        try require(discoveryCalls == 0 && controller.state == .idle && !controller.operationInProgress,
                    "Record returns before screen discovery or capture setup while syncing")
        let afterSyncGuards = try Data(contentsOf: manifestURL)
        try require(afterSyncGuards == before && controller.sessions.count == 2,
                    "Blocked capture, analysis, and Trash preserve saved sessions")
        controller.refreshSessions()
        try require(controller.syncInProgress, "Refreshing the library cannot release an active sync lock")
        controller.endSessionSync()
        try require(!controller.syncInProgress && syncPublished == [false, true, false],
                    "Acquisition and release publish once to observing windows")
        try require(controller.beginSessionAnalysis(one), "Releasing sync permits analysis again")
        controller.endSessionAnalysis(one.id)
        await controller.start(configuration: captureConfiguration)
        try require(discoveryCalls == 1 && controller.errorMessage != nil,
                    "Releasing sync permits Record to reach the injected display discovery")
        try require(controller.state == .idle && !controller.operationInProgress,
                    "The permission-free no-display fixture returns to idle")
        try require(controller.beginSessionSync(), "A finished sync may be retried after capture setup fails")
        controller.endSessionSync()

        // Replacing a manifest simulates a stale row after an external library
        // change. No test calls macOS Trash, even after analysis completes.
        let replacement = RecordingSession(id: "replacement", startedAt: one.startedAt, status: "complete",
            configuration: one.configuration, displayID: 1, displayWidth: 640, displayHeight: 360, url: one.url)
        try replacement.save()
        let replacementBytes = try Data(contentsOf: manifestURL)
        do {
            try controller.trashSession(one)
            throw Failure.failed("Controller allowed Trash after on-disk identity changed")
        } catch let error as SessionLibraryError {
            try require(error == .identityChanged,
                        "Released sync permits Trash to reach normal identity checks without moving files")
        }
        controller.refreshSessions()
        try require(!controller.beginSessionAnalysis(one), "A stale session no longer in the current library cannot start analysis")
        do {
            try controller.trashSession(one)
            throw Failure.failed("Controller allowed Trash for a stale session")
        } catch let error as SessionLibraryError {
            try require(error == .sessionMissing, "Current membership is checked before Trash")
        }
        let after = try Data(contentsOf: manifestURL)
        try require(after == replacementBytes && manager.fileExists(atPath: two.url.path), "Guarded operations leave both fixture folders intact")
        controller.prepareForTermination()
        try require(!controller.beginSessionSync(), "Shutdown rejects new sync work")
        await controller.start(configuration: captureConfiguration)
        try require(discoveryCalls == 1 && controller.state == .idle && !controller.operationInProgress,
                    "The termination gate rejects Record before permissions or capture work")
        try require(!controller.beginSessionAnalysis(two), "The termination gate rejects new analysis")
        controller.cancelSessionAnalyses()
        print("PASS: shared analysis/sync locks, duplicate/path/stale membership rejection, Record/analysis/Trash exclusion and release, published changes, retry and shutdown guards; no permissions, capture, or actual Trash operation")
    }
}
