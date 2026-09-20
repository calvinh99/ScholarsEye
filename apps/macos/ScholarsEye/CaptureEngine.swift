import AppKit
import AVFoundation
import Combine
import ScreenCaptureKit
import VideoToolbox

private enum CaptureError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(message) = self { return message }; return nil }
}

struct CaptureDisplaySnapshot {
    let sources: [SCDisplay]
    let displays: [CaptureDisplay]
}

@MainActor
struct CaptureDisplayDiscovery {
    var hasScreenAccess: () -> Bool
    var load: () async throws -> CaptureDisplaySnapshot
    var mainDisplayID: () -> UInt32?
    var localDisplays: () -> [CaptureDisplay]

    static let system = CaptureDisplayDiscovery(
        hasScreenAccess: { CGPreflightScreenCaptureAccess() },
        load: {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let displays = content.displays.enumerated().map { index, display in
                let name = NSScreen.screens.first {
                    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
                }?.localizedName ?? "Display \(index + 1)"
                return CaptureDisplay(id: display.displayID, name: name, width: display.width, height: display.height)
            }
            return CaptureDisplaySnapshot(sources: content.displays, displays: displays)
        },
        mainDisplayID: { CGMainDisplayID() },
        localDisplays: {
            NSScreen.screens.compactMap { screen in
                guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
                return CaptureDisplay(id: id, name: screen.localizedName,
                    width: CGDisplayPixelsWide(id), height: CGDisplayPixelsHigh(id))
            }
        }
    )
}

enum CaptureDisplaySelection {
    static func choose(available: [UInt32], selected: UInt32?, preferred: UInt32?, main: UInt32?) -> UInt32? {
        for candidate in [selected, preferred, main].compactMap({ $0 }) {
            if available.contains(candidate) { return candidate }
        }
        return available.first
    }
}

@MainActor
final class CaptureController: ObservableObject {
    @Published var displays: [CaptureDisplay] = []
    @Published var selectedDisplayID: UInt32? {
        didSet {
            guard !applyingDiscoveredSelection, let selectedDisplayID,
                  displays.contains(where: { $0.id == selectedDisplayID }) else { return }
            preferredDisplayID = selectedDisplayID
            displayPreferences.set(Int(selectedDisplayID), forKey: Self.preferredDisplayKey)
        }
    }
    @Published private(set) var displayDiscoveryInProgress = false
    @Published private(set) var displayError: String?
    @Published private(set) var state: CaptureState = .idle
    @Published var errorMessage: String?
    @Published private(set) var stats = CaptureStats()
    @Published private(set) var sessions: [RecordingSession] = []
    @Published private(set) var analyzingSessionIDs: Set<String> = []
    @Published private(set) var syncInProgress = false
    @Published private(set) var diagnostics: RecordingDiagnosticsSnapshot?

    let storageURL: URL
    private var sourceDisplays: [SCDisplay] = []
    private var stream: SCStream?
    private var worker: RecordingWorker?
    private var activeConfiguration: CaptureConfiguration?
    private var activeDisplay: SCDisplay?
    @Published private(set) var operationInProgress = false
    private var pendingFailure: String?
    private var transitionWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopWaiterCount = 0
    private var diagnosticsSampler: RecordingDiagnosticsSampler?
    private var diagnosticsSessionID: String?
    private var analysisProcesses: [String: Process] = [:]
    private var analysisShutdownRequested = false
    static let preferredDisplayKey = "ScholarsEyeSelectedDisplayID"
    private let displayPreferences: UserDefaults
    private let displayDiscovery: CaptureDisplayDiscovery
    private var preferredDisplayID: UInt32?
    private var applyingDiscoveredSelection = false
    private var displayDiscoveryTask: Task<Void, Never>?

    init(storageURL: URL, displayPreferences: UserDefaults = .standard,
         displayDiscovery: CaptureDisplayDiscovery? = nil) {
        self.storageURL = storageURL
        self.displayPreferences = displayPreferences
        self.displayDiscovery = displayDiscovery ?? .system
        if let stored = displayPreferences.object(forKey: Self.preferredDisplayKey) as? NSNumber {
            preferredDisplayID = UInt32(exactly: stored.int64Value)
        }
        refreshSessions()
    }

    /// Automatic refreshes preflight permission so opening the app cannot show
    /// a system prompt. Explicit refresh and Start may request screen access.
    func refreshDisplays(requestPermission: Bool = true) async {
        if let task = displayDiscoveryTask { await task.value; return }
        guard requestPermission || displayDiscovery.hasScreenAccess() else {
            // Display names and IDs are available without capture permission.
            // Capture sources are still obtained only by an explicit action.
            applyDisplaySnapshot(CaptureDisplaySnapshot(sources: [], displays: displayDiscovery.localDisplays()))
            displayError = "Allow screen recording in System Settings → Privacy & Security → Screen & System Audio Recording."
            return
        }
        displayDiscoveryInProgress = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.displayDiscoveryInProgress = false
                self.displayDiscoveryTask = nil
            }
            do {
                let snapshot = try await self.displayDiscovery.load()
                self.applyDisplaySnapshot(snapshot)
                self.displayError = snapshot.displays.isEmpty ? "No display is available. Connect a display and try again." : nil
            } catch {
                // Keep the last known choices on transient discovery failures.
                self.displayError = "Screen access is unavailable: \(error.localizedDescription). Enable ScholarsEye in System Settings → Privacy & Security → Screen & System Audio Recording, then try again."
            }
        }
        displayDiscoveryTask = task
        await task.value
    }

    private func applyDisplaySnapshot(_ snapshot: CaptureDisplaySnapshot) {
        sourceDisplays = snapshot.sources
        displays = snapshot.displays
        let selection = CaptureDisplaySelection.choose(available: snapshot.displays.map(\.id),
            selected: selectedDisplayID, preferred: preferredDisplayID, main: displayDiscovery.mainDisplayID())
        // A disconnected display should not erase the user's saved preference
        // while temporarily choosing an available screen.
        applyingDiscoveredSelection = true
        selectedDisplayID = selection
        applyingDiscoveredSelection = false
    }

    func start(configuration: CaptureConfiguration) async {
        guard !analysisShutdownRequested, state == .idle, !operationInProgress,
              !syncInProgress, stopWaiterCount == 0 else { return }
        operationInProgress = true
        errorMessage = nil
        diagnostics = nil
        diagnosticsSessionID = nil
        do {
            guard (1...10).contains(configuration.framesPerSecond), (640...7680).contains(configuration.maxWidth),
                  (80_000...10_000_000).contains(configuration.videoBitrate), (5...300).contains(configuration.chunkDuration) else {
                throw CaptureError.message("Recording settings are outside the supported range.")
            }
            if configuration.recordMicrophone {
                let allowed = await AVCaptureDevice.requestAccess(for: .audio)
                guard allowed else { throw CaptureError.message("Microphone access was denied. Enable it in System Settings → Privacy & Security → Microphone, or turn microphone recording off.") }
                guard AVCaptureDevice.default(for: .audio) != nil else { throw CaptureError.message("No microphone is available. Connect a microphone or turn microphone recording off.") }
            }
            // A connected display's capture source can change while another
            // recording is running. Resolve fresh sources for every new session.
            await refreshDisplays()
            if let displayError { throw CaptureError.message(displayError) }
            guard let display = sourceDisplays.first(where: { $0.displayID == selectedDisplayID }) else {
                throw CaptureError.message(displayError ?? "No display is available. Allow screen recording in System Settings and try again.")
            }
            try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
            try Self.requireAvailableStorage(at: storageURL)
            let identifier = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-") + "-" + UUID().uuidString.prefix(8)
            let folder = storageURL.appendingPathComponent(identifier, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let size = Self.outputSize(display: display, configuration: configuration)
            let manifest = RecordingSession(id: identifier, startedAt: Date(), configuration: configuration,
                                            displayID: display.displayID, displayWidth: size.width, displayHeight: size.height, url: folder)
            try manifest.save()
            let newWorker = RecordingWorker(session: manifest, onStats: { [weak self] stats in
                Task { @MainActor [weak self] in self?.stats = stats }
            }, onError: { [weak self] error in
                Task { @MainActor [weak self] in await self?.handleCaptureFailure(error, sessionID: identifier) }
            })
            worker = newWorker
            activeConfiguration = configuration
            activeDisplay = display
            stats = CaptureStats(sessionURL: folder)
            diagnosticsSessionID = identifier
            diagnosticsSampler = RecordingDiagnosticsSampler(sessionID: identifier, folder: folder) { [weak self] snapshot in
                Task { @MainActor [weak self] in
                    guard self?.diagnosticsSessionID == snapshot.sessionID,
                          snapshot.totalSamples >= (self?.diagnostics?.totalSamples ?? 0) else { return }
                    self?.diagnostics = snapshot
                }
            }
            stream = try makeStream(display: display, configuration: configuration, worker: newWorker)
            await newWorker.setAccepting(true)
            try await stream?.startCapture()
            if let failure = await newWorker.failureReason() { throw CaptureError.message(failure) }
            diagnostics = await diagnosticsSampler?.resume()
            state = .recording
        } catch {
            errorMessage = error.localizedDescription
            await pauseDiagnostics()
            diagnosticsSampler = nil
            try? await stream?.stopCapture()
            if let worker { await worker.finish(status: "failed", reason: error.localizedDescription) }
            self.worker = nil
            stream = nil
            activeDisplay = nil
            activeConfiguration = nil
            state = .idle
        }
        refreshSessions()
        await completeTransition()
    }

    func pause() async {
        guard state == .recording, !operationInProgress, let worker else { return }
        operationInProgress = true
        await pauseDiagnostics()
        do { try await stream?.stopCapture() }
        catch { errorMessage = "Pausing capture: \(error.localizedDescription)" }
        await worker.setAccepting(false)
        stream = nil
        await worker.pause()
        if await worker.failureReason() == nil { state = .paused }
        refreshSessions()
        await completeTransition()
    }

    func resume() async {
        guard state == .paused, !operationInProgress, stopWaiterCount == 0,
              let worker, let display = activeDisplay, let configuration = activeConfiguration else { return }
        operationInProgress = true
        do {
            if let failure = await worker.failureReason() { throw CaptureError.message(failure) }
            stream = try makeStream(display: display, configuration: configuration, worker: worker)
            await worker.resume()
            if let failure = await worker.failureReason() { throw CaptureError.message(failure) }
            try await stream?.startCapture()
            if let failure = await worker.failureReason() { throw CaptureError.message(failure) }
            diagnostics = await diagnosticsSampler?.resume()
            state = .recording
            errorMessage = nil
        } catch {
            await pauseDiagnostics()
            try? await stream?.stopCapture()
            await worker.setAccepting(false)
            await worker.pause()
            stream = nil
            errorMessage = "Could not resume: \(error.localizedDescription)"
        }
        await completeTransition()
    }

    func stop() async {
        guard state != .idle, state != .stopping, !operationInProgress, let worker else { return }
        operationInProgress = true
        state = .stopping
        await pauseDiagnostics()
        diagnosticsSampler = nil
        do { try await stream?.stopCapture() }
        catch { errorMessage = "Capture stopped with a warning: \(error.localizedDescription)" }
        await worker.setAccepting(false)
        stream = nil
        await worker.finish(status: "complete")
        if let failure = await worker.failureReason() { errorMessage = failure }
        self.worker = nil
        activeDisplay = nil
        activeConfiguration = nil
        state = .idle
        refreshSessions()
        await completeTransition()
    }

    /// Wait for an in-flight start/pause/resume/stop before requesting a final
    /// stop. App termination must await this, including while state is .idle
    /// during permission onboarding. New starts/resumes cannot race this wait.
    func stopAndWait() async {
        stopWaiterCount += 1
        defer { stopWaiterCount -= 1 }
        while operationInProgress {
            await withCheckedContinuation { transitionWaiters.append($0) }
        }
        if worker != nil { await stop() }
    }

    private func handleCaptureFailure(_ message: String, sessionID: String) async {
        guard worker?.sessionID == sessionID else { return }
        errorMessage = message
        pendingFailure = message
        guard !operationInProgress else { return }
        operationInProgress = true
        await completeTransition()
    }

    private func completeTransition() async {
        // A worker can fail while an async controller operation is suspended.
        // Query its queue as well as the pending callback so callback delivery
        // order cannot leave a permanently stopped worker marked as recording.
        if let worker {
            let workerFailure = await worker.failureReason()
            if let message = pendingFailure ?? workerFailure {
                errorMessage = message
                state = .stopping
                await pauseDiagnostics()
                diagnosticsSampler = nil
                await worker.setAccepting(false)
                try? await stream?.stopCapture()
                stream = nil
                await worker.finish(status: "failed", reason: message)
                self.worker = nil
                activeDisplay = nil
                activeConfiguration = nil
                state = .idle
                refreshSessions()
            }
        }
        pendingFailure = nil
        operationInProgress = false
        let waiters = transitionWaiters
        transitionWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func pauseDiagnostics() async {
        if let diagnosticsSampler { diagnostics = await diagnosticsSampler.pause() }
    }

    func refreshSessions() {
        guard let folders = try? FileManager.default.contentsOfDirectory(at: storageURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { sessions = []; return }
        let currentID = worker?.sessionID
        sessions = folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
                  var session = try? RecordingSession.decoder().decode(RecordingSession.self, from: data) else { return nil }
            session.url = folder
            if session.id != currentID && ["recording", "paused"].contains(session.status) {
                session.status = "interrupted"
                session.endedAt = Date()
                let knownFiles = Set(session.chunks.map(\.fileName))
                session.unfinishedFiles = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
                    .filter { $0.hasSuffix(".mp4") && !knownFiles.contains($0) }.sorted()
                session.bytesWritten = Self.directoryBytes(folder)
                try? session.save()
            }
            return session
        }.sorted { $0.startedAt > $1.startedAt }
    }

    func beginSessionAnalysis(_ session: RecordingSession, process: Process? = nil) -> Bool {
        guard !analysisShutdownRequested, !syncInProgress, !analyzingSessionIDs.contains(session.id), sessions.contains(where: {
            $0.id == session.id && $0.url.standardizedFileURL == session.url.standardizedFileURL
        }) else { return false }
        analyzingSessionIDs.insert(session.id)
        if let process { analysisProcesses[session.id] = process }
        return true
    }

    func endSessionAnalysis(_ id: String) {
        analysisProcesses.removeValue(forKey: id)
        analyzingSessionIDs.remove(id)
    }

    /// Shared by all windows; release after transfer processes and finalization stop.
    func beginSessionSync() -> Bool {
        guard !analysisShutdownRequested, !syncInProgress, state == .idle,
              !operationInProgress, analyzingSessionIDs.isEmpty else { return false }
        syncInProgress = true
        return true
    }

    func endSessionSync() { syncInProgress = false }

    /// Keep new work blocked while an asynchronous quit drains child processes.
    func prepareForTermination() { analysisShutdownRequested = true }

    /// Called during application termination. The Python analysis writer must
    /// exit before this app releases its locks and a relaunched copy can delete
    /// a session. Cancelling a Swift Task alone does not terminate its Process.
    func cancelSessionAnalyses() {
        prepareForTermination()
        let processes = Array(analysisProcesses.values)
        for process in processes where process.isRunning { process.terminate() }
        for process in processes where process.isRunning { process.waitUntilExit() }
        analysisProcesses.removeAll()
        analyzingSessionIDs.removeAll()
    }

    func trashSession(_ session: RecordingSession) throws {
        guard !syncInProgress else { throw SessionLibraryError.syncInProgress }
        guard state == .idle, !operationInProgress else { throw SessionLibraryError.captureInProgress }
        guard !analyzingSessionIDs.contains(session.id) else { throw SessionLibraryError.analysisInProgress }
        guard sessions.contains(where: {
            $0.id == session.id && $0.url.standardizedFileURL == session.url.standardizedFileURL
        }) else { throw SessionLibraryError.sessionMissing }
        try SessionLibrary.trash(session, storageURL: storageURL)
        refreshSessions()
    }

    private func makeStream(display: SCDisplay, configuration: CaptureConfiguration, worker: RecordingWorker) throws -> SCStream {
        let size = Self.outputSize(display: display, configuration: configuration)
        let capture = SCStreamConfiguration()
        capture.width = size.width
        capture.height = size.height
        capture.minimumFrameInterval = CMTime(value: 1, timescale: Int32(configuration.framesPerSecond))
        capture.queueDepth = 3
        capture.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        capture.showsCursor = true
        capture.capturesAudio = configuration.recordSystemAudio
        capture.sampleRate = 48_000
        capture.channelCount = 2
        capture.captureMicrophone = configuration.recordMicrophone
        capture.excludesCurrentProcessAudio = true
        capture.streamName = "ScholarsEye learning session"
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let result = SCStream(filter: filter, configuration: capture, delegate: worker)
        try result.addStreamOutput(worker, type: .screen, sampleHandlerQueue: worker.queue)
        if configuration.recordMicrophone { try result.addStreamOutput(worker, type: .microphone, sampleHandlerQueue: worker.queue) }
        if configuration.recordSystemAudio { try result.addStreamOutput(worker, type: .audio, sampleHandlerQueue: worker.queue) }
        return result
    }

    private static func outputSize(display: SCDisplay, configuration: CaptureConfiguration) -> (width: Int, height: Int) {
        // SCDisplay dimensions can be logical points on Retina displays. The
        // content filter supplies the actual pixel scale of this capture source.
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let scale = max(1, Double(filter.pointPixelScale))
        let sourceWidth = max(2, Int(Double(filter.contentRect.width) * scale))
        let sourceHeight = max(2, Int(Double(filter.contentRect.height) * scale))
        let width = min(sourceWidth, configuration.maxWidth) / 2 * 2
        let height = max(2, Int(Double(sourceHeight) * Double(width) / Double(sourceWidth)) / 2 * 2)
        return (width, height)
    }

    nonisolated static func directoryBytes(_ url: URL) -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    nonisolated static func requireAvailableStorage(at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values.volumeAvailableCapacityForImportantUsage, available < 10 * 1024 * 1024 * 1024 {
            throw CaptureError.message("Recording stopped to preserve 10 GiB of free disk space. Move existing recordings or free disk space before recording again.")
        }
    }
}

// All mutable capture state is confined to this queue. The capture queue is
// bounded by ScreenCaptureKit's 3-frame queue; we retain only one screen frame,
// write audio immediately, and never queue arrays of raw video/audio samples.
private final class RecordingWorker: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "app.scholarseye.capture", qos: .userInitiated)
    let sessionID: String
    private var session: RecordingSession
    private let onStats: (CaptureStats) -> Void
    private let onError: (String) -> Void
    private var accepting = false
    private var failed = false
    private var lastScreen: CMSampleBuffer?
    private var timer: DispatchSourceTimer?
    private var current: ChunkWriter?
    // One retired writer remains open briefly for delayed callbacks from the
    // other audio source. No arrays of audio buffers are retained.
    private var retiring: (writer: ChunkWriter, end: CMTime)?
    private var unassignedAudioSamples = 0
    private var segmentStart: CMTime?
    private var preVideoAudio: (count: Int, latestSampleTime: CMTime)?
    private var nextChunkID = 1
    private var pendingFinalizations = 0
    private var pendingCompletions: [() -> Void] = []
    private let startedHostTime = CMClockGetTime(CMClockGetHostTimeClock())
    private var lastStatsTime: Double = -1
    private var lastStorageCheck: Double = -10

    init(session: RecordingSession, onStats: @escaping (CaptureStats) -> Void, onError: @escaping (String) -> Void) {
        self.session = session
        sessionID = session.id
        self.onStats = onStats
        self.onError = onError
        super.init()
    }

    func setAccepting(_ value: Bool) async {
        await withCheckedContinuation { continuation in
            queue.async { self.accepting = value && !self.failed; if !value { self.timer?.cancel(); self.timer = nil }; continuation.resume() }
        }
    }

    func failureReason() async -> String? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.session.failureReason) }
        }
    }

    func pause() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.accepting = false
                self.timer?.cancel(); self.timer = nil
                self.flushUnclassifiedAudio()
                self.finalizeRetiring()
                self.finalizeCurrent(at: self.hostTime())
                self.lastScreen = nil
                self.session.status = "paused"
                self.session.events.append(RecordingEvent(kind: "pause", atOffsetSeconds: self.offset(self.hostTime())))
                self.saveManifest()
                self.whenFinalized { continuation.resume() }
            }
        }
    }

    func resume() async {
        await withCheckedContinuation { continuation in
            queue.async {
                guard !self.failed else { continuation.resume(); return }
                self.session.status = "recording"
                self.session.events.append(RecordingEvent(kind: "resume", atOffsetSeconds: self.offset(self.hostTime())))
                self.lastScreen = nil
                self.segmentStart = nil
                self.preVideoAudio = nil
                self.accepting = true
                self.saveManifest()
                continuation.resume()
            }
        }
    }

    func finish(status: String, reason: String? = nil) async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.accepting = false
                self.timer?.cancel(); self.timer = nil
                self.flushUnclassifiedAudio()
                self.finalizeRetiring()
                self.finalizeCurrent(at: self.hostTime())
                self.lastScreen = nil
                self.whenFinalized {
                    self.session.status = self.failed ? "failed" : status
                    self.session.failureReason = reason ?? self.session.failureReason
                    if status == "complete", self.session.chunks.isEmpty {
                        self.session.status = "failed"
                        self.session.failureReason = self.session.failureReason ?? "No video frames were captured. Check screen access and try again."
                        self.onError(self.session.failureReason!)
                    }
                    self.session.endedAt = Date()
                    self.session.events.append(RecordingEvent(kind: "stop", atOffsetSeconds: self.offset(self.hostTime())))
                    let known = Set(self.session.chunks.map(\.fileName))
                    self.session.unfinishedFiles = ((try? FileManager.default.contentsOfDirectory(atPath: self.session.url.path)) ?? [])
                        .filter { $0.hasSuffix(".mp4") && !known.contains($0) }.sorted()
                    self.saveManifest()
                    self.publishStats(force: true)
                    continuation.resume()
                }
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { self.fail("Screen recording stopped: \(error.localizedDescription)") }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard accepting, !failed, sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        if type == .screen {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let rawStatus = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: rawStatus) == .complete,
                  CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
            lastScreen = sampleBuffer
            if timer == nil { startFrameTimer() }
        } else {
            let count = CMSampleBufferGetNumSamples(sampleBuffer)
            let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard time.isNumeric,
                  let format = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let description = CMAudioFormatDescriptionGetStreamBasicDescription(format),
                  description.pointee.mSampleRate > 0 else { countDroppedAudio(count); return }
            let rate = description.pointee.mSampleRate
            guard lastScreen != nil else {
                // Retain only aggregate timing, never pending PCM buffers. Once
                // video establishes a segment start, this proves whether all
                // of the skipped preroll was outside the recorded interval.
                if count > 0 {
                    let last = time + CMTime(seconds: Double(count - 1) / rate, preferredTimescale: 1_000_000_000)
                    preVideoAudio = ((preVideoAudio?.count ?? 0) + count,
                                     max(preVideoAudio?.latestSampleTime ?? last, last))
                }
                return
            }
            let end = time + CMTime(seconds: Double(count) / rate, preferredTimescale: 1_000_000_000)
            do {
                // Rotate before appending a buffer which crosses the boundary,
                // so each side can be copied at a PCM sample boundary.
                try ensureChunk(at: end, initialTime: time)
                var assigned = 0
                if let retiring {
                    assigned += appendAudio(sampleBuffer, type: type, rate: rate,
                                            to: retiring.writer, until: retiring.end)
                }
                if let current {
                    assigned += appendAudio(sampleBuffer, type: type, rate: rate,
                                            to: current, until: current.start + chunkInterval)
                }
                let unassigned = max(0, count - assigned)
                let alignment = min(unassigned, AudioSampleRange.alignmentPrefix(sampleBuffer, before: segmentStart))
                if let current, alignment > 0 {
                    current.record.alignmentTrimmedAudioSamples = (current.record.alignmentTrimmedAudioSamples ?? 0) + alignment
                }
                countDroppedAudio(unassigned - alignment)
            } catch { fail(error.localizedDescription) }
        }
        publishStats()
    }

    private func startFrameTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        self.timer = timer
        let interval = 1.0 / Double(session.configuration.framesPerSecond)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.writeFrame() }
        timer.resume()
    }

    private func writeFrame() {
        guard accepting, !failed, let screen = lastScreen else { return }
        let time = hostTime()
        do {
            try ensureChunk(at: time)
            if let current, CMTimeGetSeconds(time - current.lastVideoTime) >= 0.5 / Double(session.configuration.framesPerSecond) {
                current.appendVideo(screen, at: time, framesPerSecond: session.configuration.framesPerSecond)
                if let error = current.writer.error { fail("Video encoding failed: \(error.localizedDescription)") }
            }
        } catch { fail(error.localizedDescription) }
        publishStats()
    }

    private var chunkInterval: CMTime {
        CMTime(seconds: session.configuration.chunkDuration, preferredTimescale: 1_000_000_000)
    }

    private func ensureChunk(at time: CMTime, initialTime: CMTime? = nil) throws {
        var start = initialTime ?? time
        if let current, time >= current.start + chunkInterval {
            let boundary = current.start + chunkInterval
            finalizeRetiring()
            retiring = (current, boundary)
            self.current = nil
            start = boundary
            // Normal source callbacks arrive within a few audio packets. The
            // fixed grace interval bounds both latency and open encoder count.
            queue.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self, weak current] in
                guard let self, let current, self.retiring?.writer === current else { return }
                self.finalizeRetiring()
            }
        }
        if current == nil {
            guard let lastScreen else { return }
            guard pendingFinalizations < 2 else { throw CaptureError.message("Storage cannot keep up with recording. The completed chunks have been preserved.") }
            let chunk = try ChunkWriter(folder: session.url, id: nextChunkID, configuration: session.configuration,
                                        width: session.displayWidth, height: session.displayHeight, start: start, offset: offset(start))
            nextChunkID += 1
            current = chunk
            if segmentStart == nil { segmentStart = start }
            chunk.record.droppedAudioSamples += unassignedAudioSamples
            unassignedAudioSamples = 0
            if let preVideoAudio {
                if preVideoAudio.latestSampleTime < start {
                    chunk.record.alignmentTrimmedAudioSamples = preVideoAudio.count
                } else {
                    // Any overlap or uncertain ordering stays a real loss.
                    chunk.record.droppedAudioSamples += preVideoAudio.count
                }
                self.preVideoAudio = nil
            }
            // Seed every chunk, including an unchanged screen after 60 seconds.
            chunk.appendVideo(lastScreen, at: start, framesPerSecond: session.configuration.framesPerSecond)
        }
    }

    private func appendAudio(_ sample: CMSampleBuffer, type: SCStreamOutputType, rate: Double,
                             to chunk: ChunkWriter, until end: CMTime) -> Int {
        let count = CMSampleBufferGetNumSamples(sample)
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        let range = AudioSampleRange.intersection(sampleCount: count, sampleRate: rate,
                                                  sampleTime: time, start: chunk.start, end: end)
        guard !range.isEmpty else { return 0 }
        if range.count == count {
            chunk.appendAudio(sample, type: type)
        } else {
            if let portion = AudioSampleRange.copyPCM(sample, range: range) { chunk.appendAudio(portion, type: type) }
            else { chunk.record.droppedAudioSamples += range.count }
        }
        if let error = chunk.writer.error { fail("Audio encoding failed: \(error.localizedDescription)") }
        return range.count
    }

    private func countDroppedAudio(_ count: Int) {
        guard count > 0 else { return }
        if let current { current.record.droppedAudioSamples += count }
        else if let retiring { retiring.writer.record.droppedAudioSamples += count }
        else { unassignedAudioSamples += count }
    }

    private func flushUnclassifiedAudio() {
        // Stopping before a first frame leaves no proven segment boundary.
        // Keep those samples as drops, including a very short resumed segment.
        unassignedAudioSamples += preVideoAudio?.count ?? 0
        preVideoAudio = nil
        let pending = unassignedAudioSamples
        unassignedAudioSamples = 0
        if current == nil, retiring == nil, !session.chunks.isEmpty {
            session.chunks[session.chunks.count - 1].droppedAudioSamples += pending
        } else { countDroppedAudio(pending) }
    }

    private func finalizeRetiring() {
        guard let retiring else { return }
        self.retiring = nil
        finalize(retiring.writer, at: retiring.end)
    }

    private func finalizeCurrent(at end: CMTime) {
        guard let chunk = current else { return }
        current = nil
        finalize(chunk, at: end)
    }

    private func finalize(_ chunk: ChunkWriter, at end: CMTime) {
        pendingFinalizations += 1
        chunk.finish(at: end) { [self] result in
            queue.async {
                switch result {
                case .success(let record):
                    self.session.chunks.append(record)
                    self.session.chunks.sort { $0.id < $1.id }
                    self.session.durationSeconds = self.session.chunks.reduce(0) { $0 + $1.durationSeconds }
                    self.session.bytesWritten = self.session.chunks.reduce(0) { $0 + $1.byteCount }
                    self.saveManifest()
                case .failure(let error): self.fail("Could not finalize a recording chunk: \(error.localizedDescription)")
                }
                self.pendingFinalizations -= 1
                self.publishStats(force: true)
                if self.pendingFinalizations == 0 {
                    let completions = self.pendingCompletions
                    self.pendingCompletions.removeAll()
                    completions.forEach { $0() }
                }
            }
        }
    }

    private func whenFinalized(_ completion: @escaping () -> Void) {
        if pendingFinalizations == 0 { completion() } else { pendingCompletions.append(completion) }
    }

    private func hostTime() -> CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }
    private func offset(_ time: CMTime) -> Double { max(0, CMTimeGetSeconds(time - startedHostTime)) }

    private func saveManifest() {
        do { try session.save() }
        catch { fail("Could not save recording metadata: \(error.localizedDescription)") }
    }

    private func fail(_ message: String) {
        guard !failed else { return }
        failed = true
        accepting = false
        timer?.cancel(); timer = nil
        session.failureReason = message
        onError(message)
    }

    private func publishStats(force: Bool = false) {
        let now = offset(hostTime())
        guard force || now - lastStatsTime >= 1 else { return }
        lastStatsTime = now
        if now - lastStorageCheck >= 10 {
            lastStorageCheck = now
            do { try CaptureController.requireAvailableStorage(at: session.url) }
            catch { fail(error.localizedDescription) }
        }
        let liveDuration = (current.map { max(0, CMTimeGetSeconds(hostTime() - $0.start)) } ?? 0)
            + (retiring.map { max(0, CMTimeGetSeconds($0.end - $0.writer.start)) } ?? 0)
        let all = session.chunks + (current.map { [$0.record] } ?? []) + (retiring.map { [$0.writer.record] } ?? [])
        let bytes = CaptureController.directoryBytes(session.url)
        onStats(CaptureStats(durationSeconds: session.durationSeconds + liveDuration, bytesWritten: bytes,
                             frameCount: all.reduce(0) { $0 + $1.videoFrames }, chunkCount: session.chunks.count,
                             droppedVideoFrames: all.reduce(0) { $0 + $1.droppedVideoFrames },
                             droppedAudioSamples: all.reduce(unassignedAudioSamples) { $0 + $1.droppedAudioSamples }, sessionURL: session.url))
    }
}

// Half-open sample ranges assign every PCM sample to exactly one adjacent
// chunk, including buffers delivered out of order across separate sources.
enum AudioSampleRange {
    static func alignmentPrefix(_ sample: CMSampleBuffer, before segmentStart: CMTime?) -> Int {
        guard let segmentStart, segmentStart.isNumeric,
              let description = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              asbd.pointee.mSampleRate > 0 else { return 0 }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        guard time.isNumeric else { return 0 }
        return intersection(sampleCount: CMSampleBufferGetNumSamples(sample), sampleRate: asbd.pointee.mSampleRate,
                            sampleTime: time, start: time, end: segmentStart).count
    }

    static func intersection(sampleCount: Int, sampleRate: Double, sampleTime: CMTime,
                             start: CMTime, end: CMTime) -> Range<Int> {
        func index(_ time: CMTime) -> Int {
            let samples = CMTimeGetSeconds(time - sampleTime) * sampleRate
            return Int(min(Double(sampleCount), max(0, ceil(samples - 0.000_001))))
        }
        let lower = index(start)
        return lower..<max(lower, index(end))
    }

    static func copyPCM(_ sample: CMSampleBuffer, range: Range<Int>) -> CMSampleBuffer? {
        guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= CMSampleBufferGetNumSamples(sample),
              range.upperBound <= Int(Int32.max),
              let description = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              asbd.pointee.mFormatID == kAudioFormatLinearPCM else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        // Only boundary packets are copied. Cap scratch allocation at 1 MiB;
        // ordinary 20 ms stereo Float32 packets use less than 8 KiB.
        let planes = format.isInterleaved ? 1 : Int(format.channelCount)
        let bytes = Double(range.count) * Double(asbd.pointee.mBytesPerFrame) * Double(planes)
        guard bytes > 0, bytes <= 1_048_576,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(range.count)) else { return nil }
        pcm.frameLength = AVAudioFrameCount(range.count)
        // CopySampleBufferForRange cannot handle ScreenCaptureKit's planar
        // system audio. This PCM API copies every channel's requested frames.
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: Int32(range.lowerBound),
                frameCount: Int32(range.count), into: pcm.mutableAudioBufferList) == noErr else { return nil }
        var timing = CMSampleTimingInfo()
        guard CMSampleBufferGetSampleTimingInfo(sample, at: 0, timingInfoOut: &timing) == noErr,
              timing.duration.isNumeric, timing.duration > .zero else { return nil }
        timing.presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sample)
            + CMTimeMultiply(timing.duration, multiplier: Int32(range.lowerBound))
        timing.decodeTimeStamp = .invalid
        var output: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                makeDataReadyCallback: nil, refcon: nil, formatDescription: description,
                sampleCount: range.count, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &output) == noErr,
              let output,
              CMSampleBufferSetDataBufferFromAudioBufferList(output, blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList) == noErr,
              CMSampleBufferSetDataReady(output) == noErr else { return nil }
        return output
    }
}

private final class ChunkWriter {
    let writer: AVAssetWriter
    let start: CMTime
    var lastVideoTime = CMTime.negativeInfinity
    var record: RecordingChunk
    private let video: AVAssetWriterInput
    private var microphone: AVAssetWriterInput?
    private var systemAudio: AVAssetWriterInput?
    private var lastMicrophoneTime = CMTime.negativeInfinity
    private var lastSystemAudioTime = CMTime.negativeInfinity
    private let url: URL

    init(folder: URL, id: Int, configuration: CaptureConfiguration, width: Int, height: Int, start: CMTime, offset: Double) throws {
        self.start = start
        url = folder.appendingPathComponent(String(format: "chunk-%06d.mp4", id))
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
        let codec: VideoCodec = configuration.codec == .hevc && Self.hasHardwareHEVC ? .hevc : .h264
        let settings: [String: Any] = [
            AVVideoCodecKey: codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoEncoderSpecificationKey: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: configuration.videoBitrate,
                AVVideoExpectedSourceFrameRateKey: configuration.framesPerSecond,
                AVVideoMaxKeyFrameIntervalKey: configuration.framesPerSecond * 10,
                AVVideoAllowFrameReorderingKey: false
            ]
        ]
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else { throw CaptureError.message("The selected video settings are unsupported. Try H.264 or a smaller width.") }
        video = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { throw CaptureError.message("Could not create the video encoder.") }
        writer.add(video)
        record = RecordingChunk(id: id, fileName: url.lastPathComponent, codec: codec, startOffsetSeconds: offset, durationSeconds: 0)
        if configuration.recordMicrophone {
            microphone = try Self.audioInput(writer: writer, sampleRate: 24_000, channels: 1, bitrate: 48_000)
        }
        if configuration.recordSystemAudio {
            systemAudio = try Self.audioInput(writer: writer, sampleRate: 48_000, channels: 2, bitrate: 96_000)
        }
        guard writer.startWriting() else { throw writer.error ?? CaptureError.message("Could not start hardware video encoding. Try H.264.") }
        writer.startSession(atSourceTime: start)
    }

    private static let hasHardwareHEVC: Bool = {
        var encoders: CFArray?
        guard VTCopyVideoEncoderList(nil, &encoders) == noErr,
              let encoders = encoders as? [[String: Any]] else { return false }
        return encoders.contains {
            ($0[kVTVideoEncoderList_CodecType as String] as? NSNumber)?.uint32Value == kCMVideoCodecType_HEVC &&
            ($0[kVTVideoEncoderList_IsHardwareAccelerated as String] as? Bool) == true
        }
    }()

    private static func audioInput(writer: AVAssetWriter, sampleRate: Double, channels: Int, bitrate: Int) throws -> AVAssetWriterInput {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate,
                                     AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: bitrate]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw CaptureError.message("Could not create an audio encoder.") }
        writer.add(input)
        return input
    }

    func appendVideo(_ sample: CMSampleBuffer, at time: CMTime, framesPerSecond: Int) {
        guard writer.status == .writing, video.isReadyForMoreMediaData, time > lastVideoTime else {
            record.droppedVideoFrames += 1
            return
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(framesPerSecond)), presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var output: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
                                                    sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &output) == noErr,
              let output, video.append(output) else { record.droppedVideoFrames += 1; return }
        lastVideoTime = time
        record.videoFrames += 1
    }

    func appendAudio(_ sample: CMSampleBuffer, type: SCStreamOutputType) {
        let isMicrophone = type == .microphone
        guard let input = isMicrophone ? microphone : systemAudio else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        let last = isMicrophone ? lastMicrophoneTime : lastSystemAudioTime
        guard writer.status == .writing, input.isReadyForMoreMediaData, time >= start, time > last, input.append(sample) else {
            record.droppedAudioSamples += CMSampleBufferGetNumSamples(sample)
            return
        }
        if isMicrophone { lastMicrophoneTime = time; record.microphoneSamples += CMSampleBufferGetNumSamples(sample) }
        else { lastSystemAudioTime = time; record.systemAudioSamples += CMSampleBufferGetNumSamples(sample) }
    }

    func finish(at end: CMTime, completion: @escaping (Result<RecordingChunk, Error>) -> Void) {
        guard writer.status == .writing else { completion(.failure(writer.error ?? CaptureError.message("A chunk writer stopped before finalization."))); return }
        let end = max(end, start + CMTime(seconds: 0.001, preferredTimescale: 600))
        record.durationSeconds = max(0, CMTimeGetSeconds(end - start))
        writer.endSession(atSourceTime: end)
        video.markAsFinished()
        microphone?.markAsFinished()
        systemAudio?.markAsFinished()
        writer.finishWriting { [self] in
            guard writer.status == .completed else { completion(.failure(writer.error ?? CaptureError.message("The media writer did not complete."))); return }
            record.byteCount = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            completion(.success(record))
        }
    }
}
