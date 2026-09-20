import SwiftUI

/// Capture controls stay in the window header independently of the selected page.
struct RecordingControls: View {
    let state: CaptureState
    let elapsed: Double
    let busy: Bool
    let updateInProgress: Bool
    let start: () -> Void
    let pauseOrResume: () -> Void
    let stop: () -> Void

    private let ink = Color(red: 41.0 / 255, green: 41.0 / 255, blue: 38.0 / 255)
    private var transitioning: Bool { busy || state == .stopping }
    private var status: String {
        switch state {
        case .idle: return "Ready"
        case .recording: return "Recording"
        case .paused: return "Paused"
        case .stopping: return "Saving…"
        }
    }

    var body: some View {
        Group {
            if state == .idle {
                Button(action: start) {
                    HStack(spacing: 8) {
                        if busy {
                            ProgressView().controlSize(.mini).colorScheme(.dark)
                                .frame(width: 10, height: 10)
                        } else {
                            Circle().fill(.white).frame(width: 7, height: 7)
                                .accessibilityHidden(true)
                        }
                        Text(busy ? "Starting…" : "Record").fontWeight(.medium)
                    }
                    .frame(minWidth: 77, minHeight: 32)
                    .padding(.horizontal, 12)
                }
                .buttonStyle(RecordingHeaderButtonStyle(prominent: true))
                .disabled(busy || updateInProgress)
                .accessibilityLabel(busy ? "Starting recording" : "Record")
                .help(updateInProgress ? "Wait for the update to finish before recording." : "Record a learning session")
            } else {
                HStack(spacing: 10) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(state == .recording ? Color(red: 0.82, green: 0.29, blue: 0.23) : Color.secondary)
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                        Text(status).foregroundStyle(state == .recording ? ink : .secondary)
                            .frame(width: 59, alignment: .leading)
                    }
                    RecordingElapsedLabel(state: state, elapsed: elapsed)
                        .frame(width: 76, alignment: .trailing)
                    Button(action: pauseOrResume) {
                        Image(systemName: state == .paused ? "play.fill" : "pause.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 28, height: 30)
                    }
                    .buttonStyle(RecordingHeaderButtonStyle())
                    .disabled(transitioning)
                    .accessibilityLabel(state == .paused ? "Resume recording" : "Pause recording")
                    .help(state == .paused ? "Resume recording" : "Pause recording")
                    Button(action: stop) {
                        HStack(spacing: 6) {
                            Image(systemName: "stop.fill").font(.system(size: 8))
                            Text("Stop & save").fontWeight(.medium)
                        }
                        .padding(.horizontal, 10).frame(height: 30)
                    }
                    .buttonStyle(RecordingHeaderButtonStyle())
                    .disabled(transitioning)
                    .accessibilityLabel("Stop and save recording")
                    .help("Stop and save recording")
                }
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Color(red: 0.965, green: 0.965, blue: 0.956), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(ink)
        .fixedSize(horizontal: true, vertical: true)
    }
}

/// Only the small time label ticks. Its anchor survives unrelated parent updates,
/// and a pause/stop renders the authoritative captured duration without a timer.
private struct RecordingElapsedLabel: View {
    let state: CaptureState
    let elapsed: Double
    @State private var anchorElapsed: Double = 0
    @State private var anchorInstant = ContinuousClock.now
    @State private var scheduleDate = Date()

    var body: some View {
        Group {
            if state == .recording {
                TimelineView(.periodic(from: scheduleDate, by: 1)) { _ in
                    let interval = anchorInstant.duration(to: ContinuousClock.now).components
                    let seconds = Double(interval.seconds) + Double(interval.attoseconds) / 1e18
                    time(anchorElapsed + max(0, seconds))
                }
            } else {
                time(elapsed)
            }
        }
        .onAppear { anchor() }
        .onChange(of: state) { _, newState in
            if newState == .recording { anchor() }
        }
    }

    private func anchor() {
        anchorElapsed = elapsed.isFinite ? max(0, elapsed) : 0
        anchorInstant = ContinuousClock.now
        // Wall time schedules redraws only; it never determines elapsed time.
        scheduleDate = Date()
    }

    private func time(_ value: Double) -> some View {
        let seconds = Int(value.isFinite ? min(max(0, value), 359_999_999) : 0)
        let hours = seconds / 3600
        let minutes = (seconds / 60) % 60
        let remainder = seconds % 60
        return Text(String(format: "%02d:%02d:%02d", hours, minutes, remainder))
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .monospacedDigit()
            .accessibilityLabel("Recorded time")
            .accessibilityValue("\(hours) hours, \(minutes) minutes, \(remainder) seconds")
        // No live-region announcements or digit animation: the value remains
        // available on focus without speaking or animating every second.
    }
}

private struct RecordingHeaderButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(prominent ? Color.white : Color(red: 41.0 / 255, green: 41.0 / 255, blue: 38.0 / 255))
            .background {
                RoundedRectangle(cornerRadius: 7)
                    .fill(prominent ? Color(red: 41.0 / 255, green: 41.0 / 255, blue: 38.0 / 255)
                          : Color.black.opacity(configuration.isPressed ? 0.08 : 0.035))
            }
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
    }
}
