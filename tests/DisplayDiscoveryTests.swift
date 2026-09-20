import Foundation

private enum Failure: Error, LocalizedError {
    case failed(String)
    var errorDescription: String? { if case .failed(let message) = self { return message }; return nil }
}
private func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw Failure.failed(message) }
}

@MainActor
private final class DiscoveryStub {
    var granted = true
    var main: UInt32? = 10
    var available = [CaptureDisplay(id: 10, name: "Main", width: 1920, height: 1080),
                     CaptureDisplay(id: 20, name: "External", width: 2560, height: 1440)]
    var calls = 0
    var failure: Error?
    var suspendNext = false
    var pending: CheckedContinuation<CaptureDisplaySnapshot, Error>?
    var service: CaptureDisplayDiscovery {
        CaptureDisplayDiscovery(hasScreenAccess: { self.granted }, load: {
            self.calls += 1
            if self.suspendNext {
                self.suspendNext = false
                return try await withCheckedThrowingContinuation { self.pending = $0 }
            }
            if let failure = self.failure { throw failure }
            return CaptureDisplaySnapshot(sources: [], displays: self.available)
        }, mainDisplayID: { self.main }, localDisplays: { self.available })
    }
}

@main
struct DisplayDiscoveryTests {
    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ScholarsEyeDisplayTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "ScholarsEyeDisplayTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        try selectionPolicy()
        try await permissionAndErrors(root: root, defaults: defaults)
        try await persistence(root: root, defaults: defaults)
        try await overlappingRefreshAndStart(root: root, defaults: defaults)
        print("PASS: permission-free display inventory/selection, silent preflight, explicit source discovery, stable/restored selection, disconnect fallback, error isolation, and overlapping refresh/Start deduplication; no screen/microphone capture or production preferences")
    }

    static func selectionPolicy() throws {
        let ids: [UInt32] = [10, 20]
        try require(CaptureDisplaySelection.choose(available: ids, selected: 20, preferred: 10, main: 10) == 20, "A current valid choice remains selected")
        try require(CaptureDisplaySelection.choose(available: ids, selected: 99, preferred: 20, main: 10) == 20, "An available preferred display restores after restart")
        try require(CaptureDisplaySelection.choose(available: ids, selected: nil, preferred: 99, main: 20) == 20, "The main screen is the next fallback")
        try require(CaptureDisplaySelection.choose(available: ids, selected: nil, preferred: nil, main: 99) == 10, "The first available screen is a final fallback")
        try require(CaptureDisplaySelection.choose(available: [], selected: 10, preferred: 10, main: 10) == nil, "No display yields no invalid selection")
    }

    @MainActor
    static func permissionAndErrors(root: URL, defaults: UserDefaults) async throws {
        let stub = DiscoveryStub()
        stub.granted = false
        let controller = CaptureController(storageURL: root, displayPreferences: defaults, displayDiscovery: stub.service)
        controller.errorMessage = "Existing capture error"
        await controller.refreshDisplays(requestPermission: false)
        try require(stub.calls == 0 && !controller.displayDiscoveryInProgress, "Automatic discovery without permission must never enter ScreenCaptureKit")
        try require(controller.displays == stub.available && controller.selectedDisplayID == 10, "Connected displays are visible and selected before capture permission is granted")
        try require(controller.displayError != nil && controller.errorMessage == "Existing capture error", "Permission status stays separate from recording errors")
        controller.selectedDisplayID = 20
        try require(defaults.integer(forKey: CaptureController.preferredDisplayKey) == 20, "A selection from local inventory is persisted")
        await controller.refreshDisplays()
        try require(stub.calls == 1 && controller.selectedDisplayID == 20, "An explicit action may discover capture sources and preserve the local display selection")
        try require(controller.displayError == nil && controller.errorMessage == "Existing capture error", "Successful discovery clears only the display error")
        stub.granted = true
        await controller.refreshDisplays(requestPermission: false)
        try require(stub.calls == 2 && controller.selectedDisplayID == 20, "Permitted automatic discovery preserves the actual user choice")
        stub.failure = Failure.failed("Discovery fixture failed")
        await controller.refreshDisplays()
        try require(controller.displays == stub.available && controller.selectedDisplayID == 20, "Failed discovery preserves last known display choices")
        try require(controller.displayError?.contains("Discovery fixture failed") == true && controller.errorMessage == "Existing capture error", "Discovery failures are reported independently")
        stub.failure = nil
        stub.available = []
        await controller.refreshDisplays()
        try require(controller.displays.isEmpty && controller.selectedDisplayID == nil && controller.displayError != nil, "A completed empty discovery clears obsolete choices and explains why")
    }

    @MainActor
    static func persistence(root: URL, defaults: UserDefaults) async throws {
        defaults.set(20, forKey: CaptureController.preferredDisplayKey)
        let stub = DiscoveryStub()
        let controller = CaptureController(storageURL: root, displayPreferences: defaults, displayDiscovery: stub.service)
        await controller.refreshDisplays(requestPermission: false)
        try require(controller.selectedDisplayID == 20, "Saved display preference overrides the default main display")
        controller.selectedDisplayID = 10
        try require(defaults.integer(forKey: CaptureController.preferredDisplayKey) == 10, "Picker selection is persisted")
        stub.available.reverse()
        await controller.refreshDisplays(requestPermission: false)
        try require(controller.selectedDisplayID == 10, "Refresh and list reordering preserve a valid selection")
        let relaunched = CaptureController(storageURL: root, displayPreferences: defaults, displayDiscovery: stub.service)
        await relaunched.refreshDisplays(requestPermission: false)
        try require(relaunched.selectedDisplayID == 10, "A new controller restores the explicit selection")

        defaults.set(20, forKey: CaptureController.preferredDisplayKey)
        stub.available = stub.available.filter { $0.id == 10 }
        let disconnected = CaptureController(storageURL: root, displayPreferences: defaults, displayDiscovery: stub.service)
        await disconnected.refreshDisplays(requestPermission: false)
        try require(disconnected.selectedDisplayID == 10, "Disconnected preferred display falls back to a present screen")
        try require(defaults.integer(forKey: CaptureController.preferredDisplayKey) == 20, "Automatic fallback does not erase the user's preference")
    }

    @MainActor
    static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        throw Failure.failed("Timed out waiting for the deterministic discovery fixture")
    }

    @MainActor
    static func overlappingRefreshAndStart(root: URL, defaults: UserDefaults) async throws {
        let stub = DiscoveryStub()
        stub.suspendNext = true
        let controller = CaptureController(storageURL: root, displayPreferences: defaults, displayDiscovery: stub.service)
        let automatic = Task { await controller.refreshDisplays(requestPermission: false) }
        try await waitUntil { stub.pending != nil }
        try require(controller.displayDiscoveryInProgress, "Discovery publishes its in-progress state")
        var secondEntered = false
        let second = Task {
            secondEntered = true
            await controller.refreshDisplays(requestPermission: false)
        }
        var configuration = CaptureConfiguration()
        configuration.recordMicrophone = false
        configuration.recordSystemAudio = false
        let start = Task { await controller.start(configuration: configuration) }
        try await waitUntil { secondEntered && controller.operationInProgress }
        try require(stub.calls == 1, "Concurrent automatic refreshes and Start share one discovery")
        let pending = stub.pending
        stub.pending = nil
        pending?.resume(throwing: Failure.failed("Suspended fixture failed"))
        await automatic.value
        await second.value
        await start.value
        try require(stub.calls == 1 && !controller.displayDiscoveryInProgress && !controller.operationInProgress, "All waiters finish without a second prompt or discovery")
        try require(controller.state == .idle && controller.sessions.isEmpty, "A discovery failure never creates a recording")
        try require(controller.errorMessage?.contains("Suspended fixture failed") == true, "The explicit Start action reports the discovery failure")

        stub.failure = Failure.failed("Explicit fixture failed")
        stub.granted = false
        await controller.refreshDisplays(requestPermission: false)
        try require(stub.calls == 1 && controller.selectedDisplayID != nil, "Local inventory does not count as a capture source discovery")
        await controller.start(configuration: configuration)
        try require(stub.calls == 2, "One Record click retries discovery explicitly after missing screen access")
        try require(controller.errorMessage?.contains("Explicit fixture failed") == true, "The retry reports the current error")
    }
}
