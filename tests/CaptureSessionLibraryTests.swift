import Foundation

private enum Failure: Error { case failed(String) }
private func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw Failure.failed(message) }
}

@main
struct CaptureSessionLibraryTests {
    @MainActor
    static func main() throws {
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
        let controller = CaptureController(storageURL: root)
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

        // Replacing a manifest simulates a stale row after an external library
        // change. No test calls macOS Trash, even after analysis completes.
        let replacement = RecordingSession(id: "replacement", startedAt: one.startedAt, status: "complete",
            configuration: one.configuration, displayID: 1, displayWidth: 640, displayHeight: 360, url: one.url)
        try replacement.save()
        let replacementBytes = try Data(contentsOf: manifestURL)
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
        print("PASS: shared analysis lock, duplicate/path/stale membership rejection, independent analyses, published changes, and Trash protection; no capture or actual Trash operation")
    }
}
