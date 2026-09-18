import SwiftUI
import AVKit
import AVFoundation

/// A recording uses a compact playback timeline: saved chunks are adjacent and
/// manual pauses are omitted. Media remains on disk and AVPlayer reads on demand.
struct SessionPlayerView: View {
    let session: RecordingSession
    @StateObject private var playback = SessionPlaybackModel()

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Color.black
                if let player = playback.player {
                    SessionVideoSurface(player: player, onAttachment: playback.refreshDisplayedFrame)
                        .id(playback.videoSurfaceID)
                }
                if playback.isLoading {
                    ProgressView().controlSize(.small).tint(.white)
                        .accessibilityLabel("Loading recording")
                } else if let error = playback.errorMessage {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.circle").font(.title2)
                        Text(error).font(.system(size: 12)).multilineTextAlignment(.center)
                            .frame(maxWidth: 390)
                    }
                    .foregroundStyle(.white.opacity(0.9)).padding(24)
                    .accessibilityElement(children: .combine)
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(maxHeight: 330)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .accessibilityLabel("Recorded screen video")

            SessionPlaybackControls(playback: playback, actionLabel: "Expand video", windowAction: playback.expandVideo)
        }
        .task(id: "\(session.id)|\(session.status)|\(session.chunks.count)|\(session.bytesWritten)|\(session.url.path)") {
            await playback.load(session)
        }
        .onDisappear { playback.release() }
    }

}

private struct SessionPlaybackControls: View {
    @ObservedObject var playback: SessionPlaybackModel
    let actionLabel: String
    let windowAction: () -> Void

    var body: some View {
    HStack(spacing: 10) {
        transportButton("Back 10 seconds", icon: "gobackward.10") {
            playback.skip(by: -10)
        }
        transportButton(playback.hasEnded ? "Replay session" : playback.isPlaying ? "Pause playback" : "Play session",
                        icon: playback.hasEnded ? "arrow.counterclockwise" : playback.isPlaying ? "pause.fill" : "play.fill") {
            playback.togglePlayback()
        }
        transportButton("Forward 10 seconds", icon: "goforward.10") {
            playback.skip(by: 10)
        }

        Slider(value: Binding(get: { playback.position }, set: { playback.previewPosition($0) }),
               in: 0...max(playback.duration, 0.001),
               onEditingChanged: { editing in
                   if editing { playback.beginScrubbing() } else { playback.endScrubbing() }
               })
            .tint(.primary)
            .accessibilityLabel("Recorded playback position, excluding pauses")
            .accessibilityValue("\(SessionPlaybackModel.timeText(playback.position)) of \(SessionPlaybackModel.timeText(playback.duration))")
            .help("Recorded time. Pauses between saved clips are skipped.")

        HStack(spacing: 3) {
            Text(SessionPlaybackModel.timeText(playback.position))
            Text("/").foregroundStyle(.tertiary)
            Text(SessionPlaybackModel.timeText(playback.duration)).foregroundStyle(.secondary)
            Text("recorded").foregroundStyle(.tertiary)
        }
        .font(.system(size: 10)).monospacedDigit()
        .fixedSize()
        .help("Recorded time. Pauses between saved clips are skipped.")

        if playback.hasMicrophone {
            audioButton("microphone", isMuted: playback.microphoneMuted,
                        icon: playback.microphoneMuted ? "mic.slash" : "mic") {
                playback.setMicrophoneMuted(!playback.microphoneMuted)
            }
        }
        if playback.hasSystemAudio {
            audioButton("system audio", isMuted: playback.systemAudioMuted,
                        icon: playback.systemAudioMuted ? "speaker.slash" : "speaker.wave.2") {
                playback.setSystemAudioMuted(!playback.systemAudioMuted)
            }
        }
        transportButton(actionLabel, icon: "arrow.up.left.and.arrow.down.right", action: windowAction)
    }
    .frame(height: 34)
    .disabled(!playback.canPlay)
    }

    private func transportButton(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13, weight: .medium))
                .frame(width: 23, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(label).help(label)
    }

    private func audioButton(_ source: String, isMuted: Bool, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12))
                .foregroundStyle(isMuted ? Color.secondary : Color.primary)
                .frame(width: 24, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(isMuted ? "Unmute" : "Mute") \(source)")
        .accessibilityValue(isMuted ? "Muted" : "Audible")
        .help("\(isMuted ? "Unmute" : "Mute") \(source)")
    }
}

private struct SessionVideoSurface: NSViewRepresentable {
    let player: AVPlayer
    var onAttachment: (() -> Void)? = nil

    func makeNSView(context: Context) -> SessionRenderingPlayerView {
        let view = SessionRenderingPlayerView()
        view.controlsStyle = .none
        view.allowsVideoFrameAnalysis = false
        view.videoGravity = .resizeAspect
        view.player = player
        view.onAttachment = onAttachment
        return view
    }

    func updateNSView(_ view: SessionRenderingPlayerView, context: Context) {
        view.onAttachment = onAttachment
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: SessionRenderingPlayerView, coordinator: ()) {
        view.onAttachment = nil
        view.player = nil
    }
}

private final class SessionRenderingPlayerView: AVPlayerView {
    var onAttachment: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            self.onAttachment?()
        }
    }
}

private struct ExpandedSessionPlayerView: View {
    @ObservedObject var playback: SessionPlaybackModel
    let toggleFullScreen: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let player = playback.player { SessionVideoSurface(player: player) }
                if let error = playback.errorMessage {
                    Text(error).font(.system(size: 13)).foregroundStyle(.white)
                        .multilineTextAlignment(.center).padding(30)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("Expanded recording video")
            SessionPlaybackControls(playback: playback, actionLabel: "Toggle fullscreen", windowAction: toggleFullScreen)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Color(nsColor: .windowBackgroundColor))
        }
    }
}

@MainActor
private final class ExpandedSessionWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    var onClose: (() -> Void)?

    init(playback: SessionPlaybackModel) {
        let available = (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(1280, available.width * 0.9, (available.height - 140) * 16 / 9)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: width * 9 / 16 + 50),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "ScholarsEye — Recording"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 390)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.delegate = self
        window.contentView = NSHostingView(rootView: ExpandedSessionPlayerView(playback: playback) { [weak self] in
            self?.window.toggleFullScreen(nil)
        })
        window.center()
    }

    func show() { window.makeKeyAndOrderFront(nil) }

    func close() {
        onClose = nil
        window.delegate = nil
        // The hosting view observes the model. Detach it to break the model ->
        // window -> hosting view -> model ownership chain during every close.
        window.contentView = nil
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        window.contentView = nil
        onClose?()
        onClose = nil
    }
}

struct SessionPlaybackSegment {
    let recordedStart: Double
    let duration: Double
    let originalStart: Double
    let fileName: String
}

struct SessionPlaybackContent {
    let composition: AVMutableComposition
    let microphoneTrackID: CMPersistentTrackID?
    let systemTrackID: CMPersistentTrackID?
    let segments: [SessionPlaybackSegment]
    let duration: Double

    /// Translate a compact playback offset back to the original session clock.
    func originalOffset(for recordedTime: Double) -> Double {
        guard let last = segments.last else { return 0 }
        let bounded = min(max(recordedTime, 0), duration)
        let segment = segments.first { bounded < $0.recordedStart + $0.duration } ?? last
        return segment.originalStart + min(max(bounded - segment.recordedStart, 0), segment.duration)
    }

    func audioMix(microphoneMuted: Bool, systemMuted: Bool) -> AVAudioMix {
        let mix = AVMutableAudioMix()
        var parameters: [AVAudioMixInputParameters] = []
        for (trackID, muted) in [(microphoneTrackID, microphoneMuted), (systemTrackID, systemMuted)] {
            guard let trackID else { continue }
            let input = AVMutableAudioMixInputParameters()
            input.trackID = trackID
            input.setVolume(muted ? 0 : 1, at: .zero)
            parameters.append(input)
        }
        mix.inputParameters = parameters
        return mix
    }
}

enum SessionPlaybackError: LocalizedError {
    case unfinished
    case noClips
    case invalidClip(String)
    case missingClip(String)
    case unreadableClip(String, String)
    case missingAudio(String)

    var errorDescription: String? {
        switch self {
        case .unfinished:
            return "This recording has not finished saving. Only completed sessions can be played here."
        case .noClips:
            return "This session has no saved video clips."
        case .invalidClip(let name):
            return "The saved timing for \(name) is invalid. The original files have not been changed."
        case .missingClip(let name):
            return "\(name) is missing or unreadable. Restore that clip to play the complete recording."
        case .unreadableClip(let name, let reason):
            return "Could not play \(name). \(reason)"
        case .missingAudio(let name):
            return "An expected audio track is missing from \(name). The complete recording cannot be played."
        }
    }
}

enum SessionCompositionBuilder {
    static func make(session: RecordingSession) async throws -> SessionPlaybackContent {
        guard session.status == "complete", session.unfinishedFiles.isEmpty else { throw SessionPlaybackError.unfinished }
        guard !session.chunks.isEmpty else { throw SessionPlaybackError.noClips }
        let composition = AVMutableComposition()
        guard let videoDestination = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw SessionPlaybackError.noClips
        }
        let microphoneDestination = session.configuration.recordMicrophone
            ? composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) : nil
        let systemDestination = session.configuration.recordSystemAudio
            ? composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) : nil
        var segments: [SessionPlaybackSegment] = []
        var cursor = CMTime.zero
        var previousSourceEnd = 0.0
        let base = session.url.resolvingSymlinksInPath().standardizedFileURL
        var seenFiles = Set<URL>()

        for chunk in session.chunks.sorted(by: { $0.startOffsetSeconds < $1.startOffsetSeconds }) {
            try Task.checkCancellation()
            guard chunk.durationSeconds.isFinite, chunk.durationSeconds > 0,
                  chunk.startOffsetSeconds.isFinite, chunk.startOffsetSeconds >= 0,
                  chunk.startOffsetSeconds >= previousSourceEnd - 0.001 else {
                throw SessionPlaybackError.invalidClip(chunk.fileName)
            }
            previousSourceEnd = chunk.startOffsetSeconds + chunk.durationSeconds
            let url = base.appendingPathComponent(chunk.fileName).resolvingSymlinksInPath().standardizedFileURL
            guard url.deletingLastPathComponent() == base, seenFiles.insert(url).inserted,
                  FileManager.default.isReadableFile(atPath: url.path) else {
                throw SessionPlaybackError.missingClip(chunk.fileName)
            }
            let asset = AVURLAsset(url: url)
            do {
                let videos = try await asset.loadTracks(withMediaType: .video)
                guard let video = videos.first, videos.count == 1 else {
                    throw SessionPlaybackError.unreadableClip(chunk.fileName, "No single screen video track was found.")
                }
                let videoRange = try await video.load(.timeRange)
                let declaredDuration = CMTime(seconds: chunk.durationSeconds, preferredTimescale: 60_000)
                let duration = CMTimeMinimum(declaredDuration, videoRange.duration)
                guard duration.isNumeric, duration.seconds > 0 else { throw SessionPlaybackError.invalidClip(chunk.fileName) }
                if segments.isEmpty { videoDestination.preferredTransform = try await video.load(.preferredTransform) }
                try videoDestination.insertTimeRange(CMTimeRange(start: videoRange.start, duration: duration), of: video, at: cursor)

                let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                let expectedCount = (microphoneDestination == nil ? 0 : 1) + (systemDestination == nil ? 0 : 1)
                guard audioTracks.count == expectedCount else { throw SessionPlaybackError.missingAudio(chunk.fileName) }
                var sourceIndex = 0
                for destination in [microphoneDestination, systemDestination] {
                    guard let destination else { continue }
                    let source = audioTracks[sourceIndex]
                    sourceIndex += 1
                    let audioRange = try await source.load(.timeRange)
                    // Preserve the microphone's startup offset, but never carry
                    // AAC tail padding into the next saved chunk.
                    let clipped = CMTimeRangeGetIntersection(audioRange, otherRange: CMTimeRange(start: videoRange.start, duration: duration))
                    if clipped.isValid, !clipped.isEmpty, clipped.duration.seconds > 0 {
                        try destination.insertTimeRange(clipped, of: source,
                                                        at: cursor + clipped.start - videoRange.start)
                    }
                }
                segments.append(SessionPlaybackSegment(recordedStart: cursor.seconds, duration: duration.seconds,
                                                       originalStart: chunk.startOffsetSeconds + videoRange.start.seconds,
                                                       fileName: chunk.fileName))
                cursor = cursor + duration
            } catch let error as SessionPlaybackError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw SessionPlaybackError.unreadableClip(chunk.fileName, error.localizedDescription)
            }
        }
        try Task.checkCancellation()
        return SessionPlaybackContent(composition: composition, microphoneTrackID: microphoneDestination?.trackID,
                                      systemTrackID: systemDestination?.trackID, segments: segments, duration: cursor.seconds)
    }
}

@MainActor
final class SessionPlaybackModel: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var isLoading = true
    @Published private(set) var errorMessage: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var hasEnded = false
    @Published private(set) var position = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var hasMicrophone = false
    @Published private(set) var hasSystemAudio = false
    @Published private(set) var microphoneMuted = false
    @Published private(set) var systemAudioMuted = false
    @Published private(set) var videoSurfaceID = UUID()

    private var content: SessionPlaybackContent?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var itemObservation: NSKeyValueObservation?
    private var playbackObservation: NSKeyValueObservation?
    private var generation = UUID()
    private var seekGeneration = UUID()
    private var isScrubbing = false
    private var isSeeking = false
    private var wasPlayingBeforeScrub = false
    private var expandedWindow: ExpandedSessionWindow?

    var canPlay: Bool { player != nil && !isLoading && errorMessage == nil }

    func load(_ session: RecordingSession) async {
        release()
        isLoading = true
        let token = generation
        do {
            let loaded = try await SessionCompositionBuilder.make(session: session)
            try Task.checkCancellation()
            guard token == generation else { return }
            content = loaded
            duration = loaded.duration
            hasMicrophone = loaded.microphoneTrackID != nil
            hasSystemAudio = loaded.systemTrackID != nil
            let item = AVPlayerItem(asset: loaded.composition)
            item.audioMix = loaded.audioMix(microphoneMuted: false, systemMuted: false)
            let newPlayer = AVPlayer(playerItem: item)
            newPlayer.actionAtItemEnd = .pause
            newPlayer.automaticallyWaitsToMinimizeStalling = true
            player = newPlayer
            itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token else { return }
                    if item.status == .readyToPlay { self.isLoading = false }
                    if item.status == .failed {
                        self.fail(item.error?.localizedDescription ?? "The recording could not be opened.")
                    }
                }
            }
            playbackObservation = newPlayer.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token else { return }
                    self.isPlaying = player.timeControlStatus != .paused
                }
            }
            timeObserver = newPlayer.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { [weak self] time in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token, !self.isScrubbing, !self.isSeeking else { return }
                    if time.seconds.isFinite { self.position = min(max(time.seconds, 0), self.duration) }
                }
            }
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token else { return }
                    self.hasEnded = true
                    self.isPlaying = false
                    self.position = self.duration
                }
            }
            failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] notification in
                let reason = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token else { return }
                    self.fail(reason ?? "Playback stopped because a saved clip could not be read.")
                }
            }
        } catch is CancellationError {
            if token == generation { isLoading = false }
        } catch {
            if token == generation { fail(error.localizedDescription) }
        }
    }

    func togglePlayback() {
        guard canPlay, let player else { return }
        if hasEnded { seek(to: 0, resume: true) }
        else if isPlaying { player.pause(); isPlaying = false }
        else { player.play(); isPlaying = true }
    }

    func skip(by amount: Double) {
        guard canPlay else { return }
        seek(to: position + amount, resume: isPlaying)
    }

    func previewPosition(_ value: Double) {
        position = min(max(value, 0), duration)
        // Keyboard/accessibility edits can arrive outside a drag gesture.
        if !isScrubbing { seek(to: position, resume: isPlaying) }
    }

    func beginScrubbing() {
        wasPlayingBeforeScrub = isPlaying
        isScrubbing = true
        player?.pause()
        isPlaying = false
    }

    func endScrubbing() {
        isScrubbing = false
        seek(to: position, resume: wasPlayingBeforeScrub)
    }

    private func seek(to value: Double, resume: Bool) {
        guard let player else { return }
        let bounded = min(max(value, 0), duration)
        position = bounded
        hasEnded = bounded >= duration
        isSeeking = true
        player.pause()
        isPlaying = false
        let token = generation
        let seekToken = UUID()
        seekGeneration = seekToken
        player.seek(to: CMTime(seconds: bounded, preferredTimescale: 60_000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, self.seekGeneration == seekToken else { return }
                self.isSeeking = false
                if finished && resume && !self.hasEnded { self.player?.play(); self.isPlaying = true }
            }
        }
    }

    func setMicrophoneMuted(_ muted: Bool) {
        microphoneMuted = muted
        updateAudioMix()
    }

    func setSystemAudioMuted(_ muted: Bool) {
        systemAudioMuted = muted
        updateAudioMix()
    }

    func expandVideo() {
        guard canPlay, player != nil else { return }
        if let expandedWindow { expandedWindow.show(); return }
        let expanded = ExpandedSessionWindow(playback: self)
        expanded.onClose = { [weak self] in
            self?.expandedWindow = nil
            // Reattach the inline rendering surface after AVKit's other view
            // has released the same player. Playback position is unchanged.
            self?.videoSurfaceID = UUID()
        }
        expandedWindow = expanded
        expanded.show()
    }

    func refreshDisplayedFrame() {
        guard canPlay, let player, !isScrubbing else { return }
        let current = player.currentTime().seconds
        guard current.isFinite else { return }
        // Reattaching AVKit's inline view while paused can show its initial
        // frame. A precise seek after attachment asks it to render this time.
        let resume = player.timeControlStatus != .paused
        seek(to: current, resume: resume)
    }

    private func updateAudioMix() {
        player?.currentItem?.audioMix = content?.audioMix(microphoneMuted: microphoneMuted, systemMuted: systemAudioMuted)
    }

    private func fail(_ message: String) {
        player?.pause()
        isPlaying = false
        isLoading = false
        errorMessage = message
    }

    func release() {
        generation = UUID()
        seekGeneration = UUID()
        player?.pause()
        expandedWindow?.close()
        expandedWindow = nil
        if let observer = timeObserver { player?.removeTimeObserver(observer) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        endObserver = nil
        failureObserver = nil
        itemObservation = nil
        playbackObservation = nil
        player?.replaceCurrentItem(with: nil)
        player = nil
        content = nil
        isPlaying = false
        isLoading = false
        hasEnded = false
        isScrubbing = false
        isSeeking = false
        wasPlayingBeforeScrub = false
        position = 0
        duration = 0
        errorMessage = nil
        hasMicrophone = false
        hasSystemAudio = false
        microphoneMuted = false
        systemAudioMuted = false
    }

    static func timeText(_ seconds: Double) -> String {
        let total = Int(max(seconds.isFinite ? seconds : 0, 0))
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60) }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
