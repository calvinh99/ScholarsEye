import SwiftUI
import AppKit

enum AppPaths {
    static let recordings = URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "ScholarsEyeRecordingsPath") as? String ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/ScholarsEye").path)
    static let analysisScript = Bundle.main.object(forInfoDictionaryKey: "ScholarsEyeAnalysisScript") as? String
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var recorder: CaptureController?
    private var terminationPending = false
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        recorder?.cancelSessionAnalyses()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let recorder else { return .terminateNow }
        guard recorder.state != .idle || recorder.operationInProgress else { return .terminateNow }
        if terminationPending { return .terminateLater }
        let alert = NSAlert()
        alert.messageText = "Finish your recording before quitting?"
        alert.informativeText = "Your completed recording will remain saved on this Mac."
        alert.addButton(withTitle: "Stop and Quit")
        alert.addButton(withTitle: "Keep Recording")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        terminationPending = true
        Task {
            await recorder.stopAndWait()
            terminationPending = false
            sender.reply(toApplicationShouldTerminate: recorder.state == .idle && !recorder.operationInProgress)
        }
        return .terminateLater
    }
}

@main
struct ScholarsEyeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var recorder = CaptureController(storageURL: AppPaths.recordings)
    @StateObject private var updates = UpdateController()

    var body: some Scene {
        WindowGroup("ScholarsEye") {
            MainView(recorder: recorder, updates: updates)
                .onAppear {
                    delegate.recorder = recorder
                    updates.start { [weak recorder] in
                        guard let recorder else { return true }
                        return recorder.state != .idle || recorder.operationInProgress
                    }
                }
        }
        .defaultSize(width: 1080, height: 800)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updates.checkForUpdates() }
                    .disabled(updates.blocksRecording)
            }
        }
        MenuBarExtra("ScholarsEye", systemImage: recorder.state == .recording ? "record.circle.fill" : "eye") {
            Text(recorder.state == .recording ? "Recording your learning" : recorder.state == .paused ? "Recording paused" : "ScholarsEye")
            if recorder.state == .recording {
                Button("Pause Recording") { Task { await recorder.pause() } }
                    .disabled(recorder.operationInProgress)
            } else if recorder.state == .paused {
                Button("Resume Recording") { Task { await recorder.resume() } }
                    .disabled(recorder.operationInProgress)
            }
            if recorder.state != .idle {
                Button("Stop Recording") { Task { await recorder.stopAndWait() } }
                    .disabled(recorder.state == .stopping)
            }
            Divider()
            Button(updates.phase == .available ? updates.buttonTitle : "Check for Updates…") {
                if updates.phase == .available { updates.installUpdate() }
                else { updates.checkForUpdates() }
            }.disabled(updates.isBusy || (updates.phase == .available && (recorder.state != .idle || recorder.operationInProgress)))
            Button("Show ScholarsEye") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
            }
            Button("Quit ScholarsEye") { NSApp.terminate(nil) }
        }
    }
}
