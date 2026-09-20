import SwiftUI

/// Manual synchronization settings, embedded in the main Settings form.
struct SyncSettingsView: View {
    @ObservedObject var sync: SyncController
    let unavailable: Bool
    let localStorageURL: URL

    private var canStart: Bool {
        !unavailable && !sync.isSyncing
            && !sync.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !sync.remotePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Section {
            LabeledContent("SSH host") {
                TextField("SSH host", text: $sync.host, prompt: Text("macmini"))
                    .labelsHidden().textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Master server SSH host")
                    .help("Use a host from your SSH configuration, such as macmini.")
                    .disabled(sync.isSyncing)
            }
            LabeledContent("Remote folder") {
                TextField("Remote folder", text: $sync.remotePath, prompt: Text("~/Movies/ScholarsEye"))
                    .labelsHidden().textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Master server recordings folder")
                    .disabled(sync.isSyncing)
            }
            HStack(spacing: 10) {
                if sync.isSyncing {
                    Button("Cancel") { sync.cancel() }
                        .accessibilityLabel("Cancel session sync")
                    if sync.progressFraction?.isFinite != true {
                        ProgressView().controlSize(.mini)
                            .accessibilityLabel("Syncing sessions")
                    }
                } else {
                    Button("Sync now") { if canStart { sync.start() } }
                        .disabled(!canStart)
                        .accessibilityLabel("Sync sessions with master server")
                        .help(unavailable ? "Finish recording, checking media, or updating before syncing."
                              : "Sync completed sessions in \(localStorageURL.path) with the master server.")
                }
                Spacer(minLength: 8)
                if let lastSync = sync.lastSyncAt {
                    Text("Last synced \(lastSync.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if sync.isSyncing, let progress = sync.progressFraction, progress.isFinite {
                ProgressView(value: min(max(progress, 0), 1))
                    .accessibilityLabel("Session sync progress")
            }
            if let error = sync.errorMessage, !error.isEmpty {
                Text(error)
                    .font(.system(size: 11)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if !sync.status.isEmpty {
                Text(sync.status)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        } header: {
            Text("Master server")
        } footer: {
            Text("Uses your SSH configuration. Copies completed recordings both ways; deleting one copy leaves the other.")
        }
    }
}
