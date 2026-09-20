import Foundation

private enum TestFailure: Error { case failed(String) }
private func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw TestFailure.failed(message) }
}

@main
struct SessionAnalysisLifecycleTests {
    @MainActor
    static func main() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("ScholarsEyeAnalysis-" + UUID().uuidString)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        let folder = root.appendingPathComponent("session-one")
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        let session = RecordingSession(id: "session-one", startedAt: Date(), status: "complete",
            configuration: CaptureConfiguration(), displayID: 1, displayWidth: 640,
            displayHeight: 360, url: folder)
        try session.save()
        let recorder = CaptureController(storageURL: root)
        let ready = folder.appendingPathComponent("analysis-started")
        let report = folder.appendingPathComponent("analysis.json")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import pathlib,sys,time; pathlib.Path(sys.argv[1]).write_text('started'); time.sleep(3); pathlib.Path(sys.argv[2]).write_text('{}')", ready.path, report.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // Production launch registers and runs synchronously on the main actor.
        try expect(recorder.beginSessionAnalysis(session, process: process), "Register the analysis process")
        try expect(!recorder.beginSessionAnalysis(session), "Reject a duplicate job")
        try process.run()
        defer {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
        }
        let deadline = Date().addingTimeInterval(3)
        while !files.fileExists(atPath: ready.path) && process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        try expect(files.fileExists(atPath: ready.path), "Child analysis actually started")
        do {
            try recorder.trashSession(session)
            throw TestFailure.failed("Trash must reject a session while its analysis is running")
        } catch SessionLibraryError.analysisInProgress {}
        recorder.cancelSessionAnalyses()
        try expect(!process.isRunning, "Shutdown waits until the Python writer has exited")
        try expect(process.terminationReason == .uncaughtSignal, "The pending writer was cancelled instead of completing")
        try expect(!files.fileExists(atPath: report.path), "Cancelled analysis cannot write a report after shutdown")
        try expect(recorder.analyzingSessionIDs.isEmpty, "Release analysis locks after child exit")
        try expect(!recorder.beginSessionAnalysis(session), "Reject queued work after shutdown begins")
        recorder.endSessionAnalysis(session.id) // A late reader completion is safe.
        recorder.cancelSessionAnalyses() // Termination cleanup is idempotent.

        // A completed or failed-to-launch analysis can release its lock normally.
        let anotherController = CaptureController(storageURL: root)
        try expect(anotherController.beginSessionAnalysis(session), "Register analysis without a process for callers/tests")
        anotherController.endSessionAnalysis(session.id)
        try expect(anotherController.beginSessionAnalysis(session), "A completed job permits a later check")
        anotherController.endSessionAnalysis(session.id)
        print("PASS: shared analysis lock, duplicate/trash guards, actual child cancellation and exit, no late report, shutdown launch rejection, and normal completion/retry")
    }
}
