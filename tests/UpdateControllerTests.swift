import Foundation
import Sparkle

private enum Failure: Error, CustomStringConvertible {
    case failed(String)
    var description: String { switch self { case .failed(let message): return message } }
}

@MainActor
private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw Failure.failed(message) }
}

@main
struct UpdateControllerTests {
    @MainActor
    static func main() {
        do {
            try configurationPolicy()
            try explicitInstallationAndRecordingGuards()
            try refreshingLatestAndCancelingIntent()
            try sdkReadinessTransitions()
            try cancellationAndFailures()
            try progressAndSuccessfulCompletion()
            print("PASS: updater URL/key policy, explicit fresh-release consent, recording race protection, stale-offer dismissal, cancellation/errors, bounded progress, completion, and guard release")
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor
    static func completeRefresh(_ controller: UpdateController, version: String = "0.3.1",
                                reply: @escaping (SPUUserUpdateChoice) -> Void = { _ in }) throws {
        controller.dismissUpdateInstallation()
        try require(controller.finishOfferedUpdateCycle(error: nil), "A clicked offer schedules one fresh check after SDK dismissal")
        try require(controller.claimInstallRefreshReadiness(sessionInProgress: false, canCheckForUpdates: true), "A fresh check waits for SDK readiness")
        controller.offerUpdate(version: version, notes: "Fresh release", reply: reply)
    }

    @MainActor
    static func sdkReadinessTransitions() throws {
        let controller = UpdateController()
        controller.start { false }
        try require(!controller.claimInstallRefreshReadiness(sessionInProgress: false, canCheckForUpdates: true), "Idle SDK readiness does not grant consent")
        controller.offerUpdate(version: "0.3.1", notes: "") { _ in }
        controller.installUpdate()
        controller.dismissUpdateInstallation()
        try require(controller.finishOfferedUpdateCycle(error: nil), "Finish callback arms a pending fresh check")
        try require(!controller.claimInstallRefreshReadiness(sessionInProgress: true, canCheckForUpdates: true), "SDK's asynchronous scheduling session must finish first")
        try require(controller.phase == .checking && controller.blocksRecording && controller.canCancel, "Waiting on readiness remains cancellable and protects capture")
        try require(!controller.claimInstallRefreshReadiness(sessionInProgress: false, canCheckForUpdates: false), "Partial readiness is insufficient")
        try require(controller.claimInstallRefreshReadiness(sessionInProgress: false, canCheckForUpdates: true), "Both SDK readiness conditions start one fresh check")
        try require(!controller.claimInstallRefreshReadiness(sessionInProgress: false, canCheckForUpdates: true), "Multiple KVO callbacks cannot start duplicate checks")
        controller.cancel()
        try require(!controller.blocksRecording && !controller.claimInstallRefreshReadiness(sessionInProgress: false, canCheckForUpdates: true), "Cancellation revokes queued readiness callbacks")
        controller.offerUpdate(version: "0.3.2", notes: "") { _ in }
        controller.installUpdate()
        controller.dismissUpdateInstallation()
        try require(controller.finishOfferedUpdateCycle(error: nil), "Retry arms a new readiness transition")
        controller.cancel()
        try require(!controller.claimInstallRefreshReadiness(sessionInProgress: false, canCheckForUpdates: true), "Cancellation before the SDK becomes ready prevents later work")
    }

    @MainActor
    static func configurationPolicy() throws {
        let key = Data(repeating: 7, count: 32).base64EncodedString()
        let goodHTTPS = ["https://example.com/appcast.xml", "https://github.com/org/repo/releases/latest/download/appcast.xml"]
        for feed in goodHTTPS {
            try require(UpdateController.validConfiguration(feed: feed, publicKey: key, allowLoopback: false), "Valid HTTPS feed rejected: \(feed)")
        }
        for key in ["invalid", "", Data(repeating: 0, count: 31).base64EncodedString(), Data(repeating: 0, count: 33).base64EncodedString()] {
            try require(!UpdateController.validConfiguration(feed: goodHTTPS[0], publicKey: key, allowLoopback: false), "Public key must decode to exactly 32 bytes")
        }
        for feed in ["http://example.com/appcast.xml", "file:///tmp/appcast.xml", "/appcast.xml",
                     "https://user:secret@example.com/appcast.xml", "https://example.com/appcast.xml#fragment",
                     "https:///appcast.xml", "ftp://example.com/appcast.xml"] {
            try require(!UpdateController.validConfiguration(feed: feed, publicKey: key, allowLoopback: false), "Unsafe or invalid feed accepted: \(feed)")
        }
        for feed in ["http://127.0.0.1:8768/appcast.xml", "http://localhost:8768/appcast.xml", "http://[::1]:8768/appcast.xml"] {
            try require(!UpdateController.validConfiguration(feed: feed, publicKey: key, allowLoopback: false), "Loopback HTTP requires explicit test opt-in")
            try require(UpdateController.validConfiguration(feed: feed, publicKey: key, allowLoopback: true), "Explicit loopback test URL rejected: \(feed)")
        }
        for feed in ["http://localhost.example.com/feed.xml", "http://127.0.0.1.example.com/feed.xml", "http://192.168.1.2/feed.xml", "http://example.com/feed.xml"] {
            try require(!UpdateController.validConfiguration(feed: feed, publicKey: key, allowLoopback: true), "Local-test exception cannot permit a remote HTTP host")
        }
    }

    @MainActor
    static func explicitInstallationAndRecordingGuards() throws {
        var recording = true
        let controller = UpdateController()
        controller.start { recording }
        var choices: [SPUUserUpdateChoice] = []
        controller.offerUpdate(version: "0.3.1", notes: "A tested update") { choices.append($0) }
        try require(controller.phase == .available && choices.isEmpty, "Finding an update must never authorize an installation")
        try require(!controller.canInstall && !controller.blocksRecording, "An available update must not interrupt an active or paused recording")
        controller.installUpdate()
        try require(choices.isEmpty && controller.phase == .available, "Install must be rejected throughout recording, pause, and finalization")
        recording = false
        try require(controller.canInstall, "Install becomes available after capture saves")
        controller.installUpdate()
        try require(choices == [.dismiss] && controller.phase == .checking && controller.blocksRecording, "Explicit Update dismisses the stale offer and excludes new capture throughout refresh")
        controller.installUpdate()
        try require(choices.count == 1, "Repeated clicks cannot authorize a second refresh")
        var newestChoices: [SPUUserUpdateChoice] = []
        try completeRefresh(controller, version: "0.3.2") { newestChoices.append($0) }
        try require(newestChoices == [.install] && choices == [.dismiss] && controller.availableVersion == "0.3.2"
                    && controller.phase == .downloading, "The user's click downloads the latest verified version, never the stale highlighted version")
        recording = true
        var readyChoice: SPUUserUpdateChoice?
        controller.showReady { readyChoice = $0 }
        try require(readyChoice == .skip && controller.phase == .failed && !controller.blocksRecording, "A recording that becomes active before restart must cancel installation")

        let unsolicited = UpdateController()
        unsolicited.start { false }
        unsolicited.offerUpdate(version: "0.3.1", notes: "") { _ in }
        var unsolicitedChoice: SPUUserUpdateChoice?
        unsolicited.showReady { unsolicitedChoice = $0 }
        try require(unsolicitedChoice == .skip, "SDK ready callbacks cannot install without the user's Update click")
    }

    @MainActor
    static func refreshingLatestAndCancelingIntent() throws {
        var recording = false
        let controller = UpdateController()
        controller.start { recording }
        try require(!controller.finishOfferedUpdateCycle(error: nil), "Unrelated SDK completion cannot create install consent")
        try require(controller.responds(to: #selector(SPUUpdaterDelegate.updater(_:didFinishUpdateCycleFor:error:))), "Sparkle can dispatch the cycle-finished callback")
        var staleChoices: [SPUUserUpdateChoice] = []
        controller.offerUpdate(version: "0.3.1", notes: "") { staleChoices.append($0) }
        controller.installUpdate()
        controller.dismissUpdateInstallation()
        try require(controller.phase == .checking && controller.blocksRecording && controller.canCancel, "SDK dismissal preserves a cancellable refresh and the recording guard")
        controller.cancel()
        try require(!controller.blocksRecording && !controller.finishOfferedUpdateCycle(error: nil), "Cancel while dismissing prevents a delayed SDK callback from refreshing or installing")
        controller.offerUpdate(version: "0.3.2", notes: "") { _ in }
        controller.installUpdate()
        controller.dismissUpdateInstallation()
        try require(controller.finishOfferedUpdateCycle(error: nil), "Fresh update check begins after dismissal")
        controller.showUserInitiatedUpdateCheck {}
        controller.cancel()
        var lateChoices: [SPUUserUpdateChoice] = []
        controller.offerUpdate(version: "0.3.3", notes: "") { lateChoices.append($0) }
        try require(lateChoices.isEmpty && controller.phase == .available, "A late fresh offer after cancellation never downloads automatically")
        controller.installUpdate()
        controller.dismissUpdateInstallation()
        try require(controller.finishOfferedUpdateCycle(error: nil), "Retry creates a new one-use refresh intent")
        recording = true
        controller.offerUpdate(version: "0.3.4", notes: "") { lateChoices.append($0) }
        try require(lateChoices == [.dismiss] && controller.phase == .available && !controller.canInstall,
                    "Capture becoming active during refresh prevents download; the latest offer stays available")
        recording = false
        controller.installUpdate()
        controller.dismissUpdateInstallation()
        try require(controller.finishOfferedUpdateCycle(error: nil), "Idle retry can check again")
        controller.showUpdateNotFoundWithError(NSError(domain: "Fixture", code: 0)) {}
        try require(controller.phase == .current && !controller.blocksRecording, "No newer release clears consent and capture lock")
        controller.offerUpdate(version: "0.3.5", notes: "") { lateChoices.append($0) }
        try require(controller.phase == .available && !controller.blocksRecording, "A future background offer cannot inherit no-update consent")
        controller.installUpdate()
        controller.dismissUpdateInstallation()
        try require(!controller.finishOfferedUpdateCycle(error: NSError(domain: "Fixture", code: 1))
                    && controller.phase == .failed && !controller.blocksRecording, "Failed dismissal releases consent and capture lock")
    }

    @MainActor
    static func cancellationAndFailures() throws {
        let controller = UpdateController()
        controller.start { false }
        var canceled = 0
        controller.showUserInitiatedUpdateCheck { canceled += 1 }
        try require(controller.phase == .checking && controller.canCancel && !controller.blocksRecording, "A check is cancelable and does not block capture")
        controller.cancel()
        controller.cancel()
        try require(canceled == 1 && controller.phase == .idle && !controller.canCancel, "Check cancellation callback runs exactly once")
        controller.offerUpdate(version: "0.3.1", notes: "") { _ in }
        controller.installUpdate()
        try completeRefresh(controller)
        controller.showDownloadInitiated { canceled += 1 }
        controller.cancel()
        try require(canceled == 2 && !controller.blocksRecording && controller.progress == nil, "Canceled downloads release capture and progress")
        var canceledReady: SPUUserUpdateChoice?
        controller.showReady { canceledReady = $0 }
        try require(canceledReady == .skip, "Cancel revokes prior install consent")

        controller.offerUpdate(version: "0.3.1", notes: "") { _ in }
        controller.installUpdate()
        try completeRefresh(controller)
        controller.showDownloadInitiated {}
        var acknowledged = false
        controller.showUpdaterError(NSError(domain: "Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Signature verification failed."])) { acknowledged = true }
        try require(acknowledged && controller.phase == .failed && !controller.blocksRecording && !controller.canCancel && !controller.canInstall, "Verification/network failures release all install state")
        try require(controller.message.contains("Signature verification failed."), "Meaningful SDK failure must reach the user")
        var failedReady: SPUUserUpdateChoice?
        controller.showReady { failedReady = $0 }
        try require(failedReady == .skip, "Failure revokes prior install consent")

        let dismissed = UpdateController()
        dismissed.start { false }
        dismissed.offerUpdate(version: "0.3.1", notes: "") { _ in }
        dismissed.installUpdate()
        try completeRefresh(dismissed)
        dismissed.showDownloadDidStartExtractingUpdate()
        dismissed.dismissUpdateInstallation()
        try require(!dismissed.blocksRecording && !dismissed.canInstall && dismissed.progress == nil, "Dismissing extraction releases capture and callbacks")
        dismissed.offerUpdate(version: "0.3.1", notes: "") { _ in }
        dismissed.installUpdate()
        try completeRefresh(dismissed)
        dismissed.showReady { _ in }
        try require(dismissed.phase == .installing, "Install dismissal regression starts during installation")
        dismissed.dismissUpdateInstallation()
        try require(!dismissed.blocksRecording && !dismissed.canInstall && !dismissed.canCancel, "SDK dismissal during installation must release the recording guard")
    }

    @MainActor
    static func progressAndSuccessfulCompletion() throws {
        let controller = UpdateController()
        controller.start { false }
        controller.offerUpdate(version: "0.3.1", notes: "") { _ in }
        controller.installUpdate()
        try completeRefresh(controller)
        controller.showDownloadInitiated {}
        controller.showDownloadDidReceiveData(ofLength: 20)
        try require(controller.progress == nil, "Unknown total uses indeterminate progress")
        controller.showDownloadDidReceiveExpectedContentLength(100)
        try require(controller.progress == 0.2, "Bytes arriving before length are retained")
        controller.showDownloadDidReceiveData(ofLength: .max)
        try require(controller.progress == 1, "Download overflow cannot crash or exceed full progress")
        controller.showDownloadDidStartExtractingUpdate()
        try require(controller.phase == .extracting && controller.blocksRecording && !controller.canCancel, "Extraction continues the recording guard")
        controller.showExtractionReceivedProgress(.nan)
        try require(controller.progress == nil, "Nonfinite extraction progress is indeterminate")
        controller.showExtractionReceivedProgress(-2)
        try require(controller.progress == 0, "Extraction progress has a lower bound")
        controller.showExtractionReceivedProgress(2)
        try require(controller.progress == 1, "Extraction progress has an upper bound")
        var readyChoice: SPUUserUpdateChoice?
        controller.showReady { readyChoice = $0 }
        try require(readyChoice == .install && controller.phase == .installing && controller.blocksRecording, "Only an authorized idle app may install and restart")
        var completed = false
        controller.showUpdateInstalledAndRelaunched(true) { completed = true }
        try require(completed && controller.phase == .current && !controller.blocksRecording, "Successful completion releases capture")
        controller.dismissUpdateInstallation()
        try require(!controller.canInstall && !controller.canCancel && controller.progress == nil, "Completion dismisses obsolete callbacks")
        var acknowledged = false
        controller.showUpdateNotFoundWithError(NSError(domain: "Fixture", code: 0)) { acknowledged = true }
        try require(acknowledged && controller.availableVersion == nil && controller.phase == .current, "A no-update check clears a stale version")
    }
}
