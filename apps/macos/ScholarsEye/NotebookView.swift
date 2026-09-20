import SwiftUI
import AppKit

private enum Paper {
    static let ink = Color(red: 0.16, green: 0.16, blue: 0.15)
    static let muted = Color(red: 0.48, green: 0.48, blue: 0.46)
    static let sidebar = Color(red: 0.965, green: 0.965, blue: 0.956)
    static let line = Color.black.opacity(0.09)
}

struct MainView: View {
    @ObservedObject var recorder: CaptureController
    @ObservedObject var updates: UpdateController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var microphone = true
    @State private var systemAudio = false
    @State private var compression = "Balanced"
    @State private var codec: VideoCodec = .hevc
    @State private var selectedSession: String?
    @State private var activeSessionID: String?
    @State private var busy = false
    @State private var showSettings = false
    @State private var showDetails = false
    @State private var libraryDate = Date()
    @State private var pendingDeletion: RecordingSession?
    @State private var showDeletionConfirmation = false
    @State private var deletionError: String?
    @State private var analysisMessages: [String: String] = [:]
    @State private var analyzed: Set<String> = []
    @State private var savedDiagnostics: [String: RecordingDiagnosticsSnapshot] = [:]

    private var recording: Bool { recorder.state != .idle }
    private var selected: RecordingSession? { recorder.sessions.first { $0.id == selectedSession } }
    private var unavailable: Bool { busy || recorder.operationInProgress }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Paper.line).frame(width: 1)
            VStack(spacing: 0) {
                breadcrumb
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if let session = selected, !recording {
                            sessionDetail(session)
                        } else {
                            captureView
                        }
                        if let error = recorder.errorMessage { errorNotice(error) }
                    }
                    .frame(maxWidth: 840)
                    .padding(.horizontal, 36).padding(.top, 26).padding(.bottom, 28)
                    .frame(maxWidth: .infinity)
                }
            }.background(.white)
        }
        .foregroundStyle(Paper.ink)
        .frame(minWidth: 940, minHeight: 700)
        .preferredColorScheme(.light)
        .tint(Paper.ink)
        .onAppear {
            libraryDate = Date()
            recorder.refreshSessions()
            for session in recorder.sessions {
                analysisMessages[session.id] = reportSummary(session.url)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in libraryDate = Date() }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in libraryDate = Date() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            libraryDate = Date()
            if !recording && !unavailable { recorder.refreshSessions() }
        }
        .alert("Move session to Trash?", isPresented: $showDeletionConfirmation, presenting: pendingDeletion) { session in
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
            Button("Move to Trash", role: .destructive) { deleteSession(session) }
        } message: { session in
            Text("The session from \(session.startedAt.formatted(date: .abbreviated, time: .shortened)) and its saved files can be recovered from Trash.")
        }
        .alert("Couldn’t delete session", isPresented: Binding(get: { deletionError != nil }, set: { if !$0 { deletionError = nil } })) {
            Button("OK", role: .cancel) { deletionError = nil }
        } message: { Text(deletionError ?? "") }
        .onChange(of: selectedSession) { _, _ in
            showDetails = false
            loadSelectedDiagnostics()
        }
        .onChange(of: recorder.state) { _, state in
            if state == .recording {
                activeSessionID = recorder.stats.sessionURL?.lastPathComponent
            } else if state == .idle, let id = activeSessionID {
                recorder.refreshSessions()
                if let session = recorder.sessions.first(where: { $0.id == id }) {
                    selectedSession = id
                    if let snapshot = recorder.diagnostics, snapshot.sessionID == id {
                        savedDiagnostics[id] = snapshot
                    }
                    if session.status == "complete", !analyzed.contains(id) { runAnalysis(session) }
                }
                activeSessionID = nil
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                DoodleEye(blinking: !recording).frame(width: 35, height: 35)
                    .accessibilityHidden(true)
                Text("ScholarsEye").font(.system(size: 17, weight: .semibold))
            }.padding(.horizontal, 20).padding(.top, 28).padding(.bottom, 27)

            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { selectedSession = nil }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "plus").font(.system(size: 15, weight: .medium)).frame(width: 18, height: 18)
                    Text(recording ? "Current session" : "New session").fontWeight(.medium)
                    Spacer()
                }.padding(.horizontal, 12).padding(.vertical, 10)
                    .background(selectedSession == nil ? Color.black.opacity(0.055) : .clear, in: RoundedRectangle(cornerRadius: 6))
            }.buttonStyle(NotebookRowStyle()).padding(.horizontal, 10)
                .help(recording ? "Return to the recording" : "Record a new learning session")

            HStack {
                Text("Sessions")
                Spacer()
                Text("\(recorder.sessions.count)").monospacedDigit()
            }.font(.system(size: 11, weight: .medium)).foregroundStyle(Paper.muted)
                .padding(.horizontal, 22).padding(.top, 31).padding(.bottom, 12)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(SessionLibrary.groups(for: recorder.sessions, now: libraryDate)) { group in
                        Section {
                            ForEach(group.sessions) { session in sessionRow(session) }
                        } header: {
                            Text(group.title).font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Paper.muted)
                                .padding(.horizontal, 12).padding(.top, 13).padding(.bottom, 5)
                                .accessibilityAddTraits(.isHeader)
                        }
                    }
                    if recorder.sessions.isEmpty {
                        Text("A fresh page.").font(.system(size: 12)).foregroundStyle(Paper.muted)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }
                }.padding(.horizontal, 10)
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                Button { showSettings.toggle() } label: {
                    Label("Settings", systemImage: "gearshape")
                        .font(.system(size: 11)).foregroundStyle(Paper.muted)
                        .padding(.vertical, 8)
                }.buttonStyle(NotebookRowStyle()).help("Settings (⌘,)")
                    .keyboardShortcut(",", modifiers: .command)
                    .popover(isPresented: $showSettings, arrowEdge: .leading) { settings }
                Spacer()
                UpdateStatusView(updates: updates, recording: recording || recorder.operationInProgress)
            }.padding(.horizontal, 22).padding(.bottom, 20)
        }.frame(width: 226).background(Paper.sidebar)
    }

    private func sessionRow(_ session: RecordingSession) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { selectedSession = session.id }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text(session.startedAt.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 12, weight: selectedSession == session.id ? .semibold : .regular))
                Text(session.status == "recording" || session.status == "paused" ? "In progress" : "\(duration(session.durationSeconds)) · \(bytes(session.bytesWritten))")
                    .font(.system(size: 10)).foregroundStyle(Paper.muted)
            }.padding(.horizontal, 12).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(selectedSession == session.id ? Color.black.opacity(0.065) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(NotebookRowStyle()).disabled(recording)
            .accessibilityLabel("Session \(session.startedAt.formatted(date: .abbreviated, time: .shortened)), \(duration(session.durationSeconds))")
            .contextMenu { sessionActions(session) }
    }

    @ViewBuilder
    private func sessionActions(_ session: RecordingSession) -> some View {
        Button("Reveal in Finder", systemImage: "arrow.up.right.square") {
            NSWorkspace.shared.activateFileViewerSelecting([session.url])
        }
        Divider()
        Button("Delete session…", systemImage: "trash", role: .destructive) {
            pendingDeletion = session
            showDeletionConfirmation = true
        }.disabled(recording || unavailable || recorder.analyzingSessionIDs.contains(session.id) || updates.blocksRecording)
    }

    private var breadcrumb: some View {
        HStack(spacing: 8) {
            Text(selected != nil && !recording ? "Sessions" : "New session")
            if let session = selected, !recording {
                Text("/").foregroundStyle(.tertiary)
                Text(session.startedAt.formatted(.dateTime.month(.abbreviated).day()))
            }
            Spacer()
            if recording {
                Circle().fill(recorder.state == .recording ? Color(red: 0.82, green: 0.28, blue: 0.22) : Paper.muted).frame(width: 6, height: 6)
                Text(recorder.state == .paused ? "Paused" : recorder.state == .stopping ? "Saving…" : "Recording")
            }
        }.font(.system(size: 11)).foregroundStyle(Paper.muted)
            .padding(.horizontal, 28).frame(height: 52)
            .overlay(alignment: .bottom) { Rectangle().fill(Paper.line.opacity(0.6)).frame(height: 1) }
    }

    private var captureView: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(recording ? "A little more, remembered." : "Let’s learn something.")
                        .font(.system(size: 29, weight: .bold)).tracking(-0.7)
                    Text(recording ? "\(bytes(recorder.stats.bytesWritten)) saved on this Mac" : "Your screen. Your thinking. One place to come back to.")
                        .font(.system(size: 12)).foregroundStyle(Paper.muted)
                }
                Spacer(minLength: 10)
            }

            VStack(spacing: 22) {
                DoodleEye(blinking: !recording).frame(width: 116, height: 104)
                    .accessibilityHidden(true).padding(.top, recording ? 17 : 35)
                if recording {
                    Text(duration(recorder.stats.durationSeconds)).font(.system(size: 53, weight: .regular, design: .monospaced)).tracking(-2)
                        .contentTransition(.numericText()).accessibilityLabel("Recorded time \(duration(recorder.stats.durationSeconds))")
                    HStack(spacing: 10) {
                        Button {
                            perform { if recorder.state == .paused { await recorder.resume() } else { await recorder.pause() } }
                        } label: {
                            Label(recorder.state == .paused ? "Resume" : "Pause", systemImage: recorder.state == .paused ? "play.fill" : "pause.fill")
                                .frame(width: 95)
                        }.buttonStyle(PaperButtonStyle()).disabled(unavailable || recorder.state == .stopping)
                        Button { perform { await recorder.stop() } } label: {
                            Label("Stop & save", systemImage: "stop.fill").frame(width: 116)
                        }.buttonStyle(PaperButtonStyle(prominent: true)).disabled(unavailable || recorder.state == .stopping)
                    }
                } else {
                    HStack(spacing: 22) {
                        Toggle("Microphone", isOn: $microphone).toggleStyle(.checkbox)
                        Toggle("System audio", isOn: $systemAudio).toggleStyle(.checkbox)
                    }.font(.system(size: 12)).disabled(unavailable)
                    Button {
                        guard !updates.blocksRecording else { return }
                        selectedSession = nil
                        perform {
                            guard !updates.blocksRecording else { return }
                            await recorder.start(configuration: configuration)
                        }
                    } label: {
                        HStack(spacing: 9) {
                            if unavailable { ProgressView().controlSize(.small).colorScheme(.dark) }
                            else { Circle().fill(Color.white).frame(width: 8, height: 8) }
                            Text(unavailable ? "Starting…" : "Start recording").fontWeight(.medium)
                        }.frame(width: 188)
                    }.buttonStyle(PaperButtonStyle(prominent: true)).disabled(unavailable || updates.blocksRecording)
                        .help(updates.blocksRecording ? "Wait for the update to finish before recording." : "Start a learning session")
                    Text("1 fps  ·  \(codec == .hevc ? "HEVC" : "H.264")  ·  \(compression.lowercased())")
                        .font(.system(size: 10)).foregroundStyle(Paper.muted)
                }
            }.frame(maxWidth: .infinity).padding(.bottom, 29)
                .background(Paper.sidebar.opacity(0.48), in: RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).stroke(Paper.line, lineWidth: 1) }

            if recording {
                DiagnosticsPanel(snapshot: recorder.diagnostics, isLive: recorder.state == .recording)
                if recorder.stats.droppedAudioSamples > 0 || recorder.stats.droppedVideoFrames > 0 {
                    Label("Capture samples were dropped. Check this session after saving.", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12)).foregroundStyle(.orange)
                }
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Settings").font(.system(size: 14, weight: .semibold))
            recordingSettings.disabled(recording || unavailable)
            Divider()
            VStack(alignment: .leading, spacing: 9) {
                Text("Storage").font(.system(size: 11)).foregroundStyle(Paper.muted)
                Button("Open recordings folder", systemImage: "arrow.up.right.square") {
                    NSWorkspace.shared.open(recorder.storageURL)
                }.buttonStyle(.link)
                Text((recorder.storageURL.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 10)).foregroundStyle(Paper.muted)
                    .textSelection(.enabled).lineLimit(2).truncationMode(.middle)
            }
        }.font(.system(size: 12)).padding(22).frame(width: 340)
    }

    private var recordingSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Compression").font(.system(size: 11)).foregroundStyle(Paper.muted)
                Picker("Compression", selection: $compression) {
                    Text("Compact").tag("Compact")
                    Text("Balanced").tag("Balanced")
                    Text("More detail").tag("More detail")
                }.labelsHidden().pickerStyle(.segmented)
            }
            Picker("Format", selection: $codec) {
                Text("HEVC · smaller files").tag(VideoCodec.hevc)
                Text("H.264 · compatible").tag(VideoCodec.h264)
            }
            HStack {
                Text("Display")
                if !recorder.displays.isEmpty {
                    Picker("Display", selection: $recorder.selectedDisplayID) {
                        ForEach(recorder.displays) { display in Text(display.name).tag(Optional(display.id)) }
                    }.labelsHidden()
                }
                Spacer(minLength: 0)
                Button(recorder.displays.isEmpty ? "Choose…" : "Refresh") { perform { await recorder.refreshDisplays() } }
            }
            Text("1 frame per second. Audio stays continuous.").font(.system(size: 10)).foregroundStyle(Paper.muted)
        }
    }

    private func sessionDetail(_ session: RecordingSession) -> some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(session.startedAt.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                        .font(.system(size: 27, weight: .bold)).tracking(-0.7)
                    Text("\(session.startedAt.formatted(date: .omitted, time: .shortened))  ·  \(duration(session.durationSeconds))  ·  \(bytes(session.bytesWritten))")
                        .font(.system(size: 11)).foregroundStyle(Paper.muted)
                }
                Spacer()
                Menu { sessionActions(session) } label: {
                    Image(systemName: "ellipsis").font(.system(size: 18)).frame(width: 32, height: 30)
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("Session actions").help("Session actions")
            }
            if session.status != "complete" {
                Label(session.failureReason ?? "This recording was \(session.status). Open its folder to inspect saved files.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(.orange)
            }
            SessionPlayerView(session: session).id(session.id)
            DiagnosticsPanel(snapshot: savedDiagnostics[session.id], isLive: false)
            HStack(spacing: 8) {
                if recorder.analyzingSessionIDs.contains(session.id) { ProgressView().controlSize(.mini) }
                else { Image(systemName: analysisMessages[session.id]?.hasPrefix("Media checked") == true ? "checkmark.circle" : "info.circle").font(.system(size: 11)) }
                Text(recorder.analyzingSessionIDs.contains(session.id) ? "Checking media…" : analysisMessages[session.id] ?? "Saved locally")
                    .lineLimit(2).textSelection(.enabled)
                Spacer(minLength: 5)
                Button { showDetails.toggle() } label: { Image(systemName: "info.circle").frame(width: 24, height: 20) }
                    .buttonStyle(NotebookRowStyle()).accessibilityLabel("Session details")
                    .popover(isPresented: $showDetails) {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Session details").font(.headline)
                            Text("\(session.displayWidth) × \(session.displayHeight) · \(session.configuration.framesPerSecond) fps · \(session.configuration.codec.rawValue.uppercased())")
                            Text("\(session.chunks.count) media files · \(session.status)")
                            Button("Check saved media") { runAnalysis(session) }.disabled(recorder.analyzingSessionIDs.contains(session.id))
                            Button("Open analysis report") { NSWorkspace.shared.open(session.url.appendingPathComponent("analysis.json")) }
                                .disabled(!FileManager.default.fileExists(atPath: session.url.appendingPathComponent("analysis.json").path))
                        }.font(.system(size: 12)).padding(22)
                    }
            }.font(.system(size: 10)).foregroundStyle(Paper.muted)
        }
    }

    private func deleteSession(_ session: RecordingSession) {
        pendingDeletion = nil
        guard !recording, !unavailable, !recorder.analyzingSessionIDs.contains(session.id), !updates.blocksRecording else {
            deletionError = "Wait for recording, media checks, or updates to finish, then try again."
            return
        }
        do {
            let index = recorder.sessions.firstIndex { $0.id == session.id } ?? 0
            try recorder.trashSession(session)
            if selectedSession == session.id {
                selectedSession = recorder.sessions.isEmpty ? nil : recorder.sessions[min(index, recorder.sessions.count - 1)].id
            }
            analysisMessages.removeValue(forKey: session.id)
            savedDiagnostics.removeValue(forKey: session.id)
            analyzed.remove(session.id)
        } catch { deletionError = error.localizedDescription }
    }

    private func errorNotice(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
            VStack(alignment: .leading, spacing: 8) {
                Text(error).textSelection(.enabled)
                Button("Open recording permissions") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
                }.buttonStyle(.link)
            }
        }.font(.system(size: 12)).foregroundStyle(Color(red: 0.62, green: 0.29, blue: 0.12))
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }

    private var configuration: CaptureConfiguration {
        var result = CaptureConfiguration()
        result.recordMicrophone = microphone
        result.recordSystemAudio = systemAudio
        result.codec = codec
        result.videoBitrate = compression == "Compact" ? 250_000 : compression == "More detail" ? 800_000 : 400_000
        return result
    }

    private func perform(_ action: @escaping @MainActor () async -> Void) {
        busy = true
        Task { await action(); busy = false }
    }

    private func loadSelectedDiagnostics() {
        guard let session = selected else { return }
        let live = recorder.diagnostics.flatMap { $0.sessionID == session.id ? $0 : nil }
        let candidates = [live, savedDiagnostics[session.id], RecordingDiagnosticsSnapshot.load(from: session.url)].compactMap { $0 }
        savedDiagnostics[session.id] = candidates.max { $0.updatedAt < $1.updatedAt }
    }

    private func runAnalysis(_ session: RecordingSession) {
        guard let script = AppPaths.analysisScript, FileManager.default.fileExists(atPath: script) else {
            analysisMessages[session.id] = "Media check unavailable"
            return
        }
        let folder = session.url
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script, folder.path, "--output", folder.appendingPathComponent("analysis.json").path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        // Register and launch on the main actor without suspension, so quitting
        // can always terminate the report writer before the app exits.
        guard recorder.beginSessionAnalysis(session, process: process) else { return }
        do { try process.run() }
        catch {
            recorder.endSessionAnalysis(session.id)
            analysisMessages[session.id] = "Media check unavailable: \(error.localizedDescription)"
            return
        }
        analyzed.insert(session.id)
        analysisMessages[session.id] = "Checking media…"
        Task {
            let message = await Task.detached(priority: .utility) { () -> String in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus == 0 { return "Media checked" }
                return "Media check: " + String((String(data: data, encoding: .utf8) ?? "Unknown error").suffix(300))
            }.value
            analysisMessages[session.id] = message == "Media checked" ? reportSummary(folder) ?? message : message
            recorder.endSessionAnalysis(session.id)
        }
    }

    private func reportSummary(_ folder: URL) -> String? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("analysis.json")),
              let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              report["status"] as? String == "complete",
              let storage = report["storage"] as? [String: Any],
              let rate = (storage["estimatedBytesPerHour"] as? NSNumber)?.int64Value else { return nil }
        let warnings = report["warnings"] as? [String] ?? []
        return "\(warnings.isEmpty ? "Media checked" : "\(warnings.count) media warning(s)") · ~\(bytes(rate))/hour"
    }

    private func bytes(_ size: Int64) -> String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
    private func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60) : String(format: "%02d:%02d", total / 60, total % 60)
    }
}

private struct DiagnosticsPanel: View {
    let snapshot: RecordingDiagnosticsSnapshot?
    let isLive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 5) {
                Text("App usage").font(.system(size: 11, weight: .medium))
                Image(systemName: "info.circle").font(.system(size: 10)).foregroundStyle(Paper.muted)
                    .help("ScholarsEye process only. CPU: 100% equals one core. Memory: resident RAM. Averages cover measured recording time, excluding pauses. This excludes separate system capture/encoder services and power consumption.")
                Spacer()
                if isLive { Text("live").font(.system(size: 9)).foregroundStyle(Paper.muted) }
            }
            if let snapshot, !snapshot.samples.isEmpty {
                HStack(spacing: 24) {
                    usageMetric("CPU", value: snapshot.averageCPUPercent.map { String(format: "%.1f%%", $0) } ?? "—",
                                peak: snapshot.peakCPUPercent.map { String(format: "Peak %.1f%%", $0) },
                                values: snapshot.samples.map { ($0.elapsedActiveSeconds, $0.cpuPercent) })
                    Rectangle().fill(Paper.line).frame(width: 1, height: 45)
                    usageMetric("Memory", value: snapshot.averageResidentBytes.map { memory($0) } ?? "—",
                                peak: snapshot.peakResidentBytes.map { "Peak \(memory(Double($0)))" },
                                values: snapshot.samples.map { ($0.elapsedActiveSeconds, $0.residentBytes.map(Double.init)) })
                }
                if snapshot.measurementFailures > 0 {
                    Text("Some measurements were unavailable; averages cover valid samples.")
                        .font(.system(size: 10)).foregroundStyle(Paper.muted)
                }
                if snapshot.persistenceError != nil {
                    Text("These measurements could not be saved.").font(.system(size: 10)).foregroundStyle(.orange)
                }
            } else {
                Text(isLive ? "Collecting CPU and memory…" : "Resource measurements weren’t collected for this session.")
                    .font(.system(size: 11)).foregroundStyle(Paper.muted)
            }
        }.padding(.vertical, 14).padding(.horizontal, 16)
            .background(Paper.sidebar.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).stroke(Paper.line, lineWidth: 1) }
    }

    private func usageMetric(_ name: String, value: String, peak: String?, values: [(Double, Double?)]) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(value).font(.system(size: 17, weight: .medium, design: .rounded)).monospacedDigit()
                    Text("avg").font(.system(size: 9)).foregroundStyle(Paper.muted)
                }
                Text(name).font(.system(size: 10)).foregroundStyle(Paper.muted)
            }.fixedSize()
            VStack(alignment: .trailing, spacing: 4) {
                Sparkline(values: values).frame(height: 28).accessibilityHidden(true)
                Text(peak ?? "").font(.system(size: 8)).foregroundStyle(Paper.muted)
            }.frame(maxWidth: .infinity)
        }.frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(name), average \(value), \(peak ?? "")")
    }

    private func memory(_ value: Double) -> String { String(format: "%.0f MiB", value / 1_048_576) }
}

private struct Sparkline: View {
    let values: [(Double, Double?)]
    var body: some View {
        GeometryReader { geometry in
            let valid = values.filter { $0.0.isFinite && ($0.1?.isFinite ?? false) }
            let maxY = max(1, (valid.compactMap { $0.1 }.max() ?? 1) * 1.12)
            let minX = values.first?.0 ?? 0
            let width = max(1, (values.last?.0 ?? 1) - minX)
            ZStack(alignment: .bottom) {
                Rectangle().fill(Paper.line).frame(height: 1)
                Path { path in
                    var connected = false
                    for (x, y) in values {
                        guard x.isFinite, let y, y.isFinite else { connected = false; continue }
                        let point = CGPoint(x: (x - minX) / width * geometry.size.width,
                                            y: geometry.size.height * (1 - max(0, y) / maxY))
                        if connected { path.addLine(to: point) } else { path.move(to: point); connected = true }
                    }
                }.stroke(Paper.ink.opacity(0.7), style: StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round))
                if valid.count == 1, let y = valid.first?.1 {
                    Circle().fill(Paper.ink.opacity(0.7)).frame(width: 3, height: 3)
                        .position(x: geometry.size.width / 2, y: geometry.size.height * (1 - y / maxY))
                }
            }
        }
    }
}

private struct PaperButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12)).padding(.horizontal, 16).padding(.vertical, 12)
            .foregroundStyle(prominent ? .white : Paper.ink)
            .background(prominent ? Paper.ink.opacity(configuration.isPressed ? 0.78 : 1) : Color.white, in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).stroke(prominent ? .clear : Paper.line, lineWidth: 1) }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

private struct NotebookRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.contentShape(Rectangle()).opacity(configuration.isPressed ? 0.55 : 1)
    }
}
