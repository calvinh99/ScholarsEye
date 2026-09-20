import AppKit
import Combine
import Sparkle
import SwiftUI

/// Sparkle owns verification, replacement, rollback, and relaunch. This driver
/// supplies a small in-app UI and requires an explicit click before installation.
@MainActor
final class UpdateController: NSObject, ObservableObject, SPUUserDriver, SPUUpdaterDelegate {
    enum Phase: Equatable {
        case unconfigured, idle, checking, available, downloading, extracting, installing, current, failed
    }

    private enum InstallIntent { case none, waitingForDismissal, refreshing }

    @Published private(set) var phase: Phase = .unconfigured
    @Published private(set) var availableVersion: String?
    @Published private(set) var message = "Updates will be available once the release channel is connected."
    @Published private(set) var progress: Double?
    @Published private(set) var releaseNotes = ""
    @Published private(set) var requiresGitHubConnection = false
    @Published private(set) var canRetryRestart = false
    @Published var showDetails = false
    @Published private var installIntent: InstallIntent = .none
    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    let githubRepository = (Bundle.main.object(forInfoDictionaryKey: "ScholarsEyeGitHubRepository") as? String).flatMap { $0.isEmpty ? nil : $0 }

    private var updater: SPUUpdater?
    private var choice: ((SPUUserUpdateChoice) -> Void)?
    private var cancellation: (() -> Void)?
    private var recordingIsActive: () -> Bool = { true }
    private var userAuthorizedInstallation = false
    private var received: UInt64 = 0
    private var expected: UInt64 = 0
    private var didStart = false
    private var discoveryTask: Task<Void, Never>?
    private var privateCheckTimer: Timer?
    private var retryRestart: (() -> Void)?
    private var resolvedFeedURL: URL?
    private var archiveToken: String?
    private var installRefreshTask: Task<Void, Never>?
    private var refreshReadinessObservations: [NSKeyValueObservation] = []
    private var awaitingRefreshReadiness = false

    var blocksRecording: Bool { installIntent != .none || [.downloading, .extracting, .installing].contains(phase) }
    var isBusy: Bool { phase == .checking || blocksRecording }
    var canCancel: Bool { cancellation != nil }
    var canInstall: Bool { phase == .available && choice != nil && !recordingIsActive() }
    var configured: Bool { updater != nil }
    var buttonTitle: String {
        if requiresGitHubConnection { return "Connect GitHub" }
        switch phase {
        case .available: return "Update to \(availableVersion ?? "new version")"
        case .checking: return "Checking…"
        case .downloading: return progress.map { "Downloading \(Int($0 * 100))%" } ?? "Downloading…"
        case .extracting: return "Preparing update…"
        case .installing: return "Restarting…"
        case .current: return "Up to date"
        case .failed: return "Update couldn’t finish"
        default: return "Check for updates"
        }
    }

    func start(recordingIsActive: @escaping () -> Bool) {
        guard !didStart else { return }
        didStart = true
        self.recordingIsActive = recordingIsActive
        let info = Bundle.main.infoDictionary ?? [:]
        if info["ScholarsEyeDevelopmentBuild"] as? Bool == true,
           info["ScholarsEyeAllowsLocalUpdateFeed"] as? Bool != true {
            message = "This development copy is updated by rebuilding. Shared copies check the release channel."
            return
        }
        guard let rawURL = info["SUFeedURL"] as? String,
              let key = info["SUPublicEDKey"] as? String,
              Self.validConfiguration(feed: rawURL, publicKey: key,
                                      allowLoopback: info["ScholarsEyeAllowsLocalUpdateFeed"] as? Bool == true) else { return }
        Self.migrateAutomaticCheckPreference(githubRepository: githubRepository, defaults: .standard)
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        self.updater = updater
        do {
            try updater.start()
            phase = .idle
            message = "Checks at launch and about once an hour. Installation starts only when you choose Update."
            if githubRepository != nil {
                // GitHub's private release feed is an authenticated asset whose
                // URL changes each release. Resolve it before every SDK check.
                if updater.automaticallyChecksForUpdates { updater.automaticallyChecksForUpdates = false }
                beginPrivateCheck()
                let timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.beginPrivateCheck() }
                }
                timer.tolerance = 120
                privateCheckTimer = timer
            } else if updater.automaticallyChecksForUpdates { updater.checkForUpdatesInBackground() }
        } catch {
            self.updater = nil
            phase = .failed
            message = "Updates aren’t configured correctly. \(error.localizedDescription)"
        }
    }

    static func migrateAutomaticCheckPreference(githubRepository: String?, defaults: UserDefaults) {
        guard githubRepository?.isEmpty != false else { return }
        // Private releases disabled Sparkle's scheduler in persistent defaults.
        // Public releases use the bundle's always-on check policy again. Remove
        // that legacy override before Sparkle captures its initial settings;
        // its runtime setter would schedule a competing delayed cycle reset.
        if defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool == false {
            defaults.removeObject(forKey: "SUEnableAutomaticChecks")
        }
    }

    static func validConfiguration(feed: String, publicKey: String, allowLoopback: Bool) -> Bool {
        guard Data(base64Encoded: publicKey)?.count == 32,
              let url = URL(string: feed), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil else { return false }
        if url.scheme == "https" { return true }
        return allowLoopback && url.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(host)
    }

    func checkForUpdates() {
        showDetails = true
        guard let updater, !blocksRecording else { return }
        if phase == .available { return }
        if githubRepository != nil { beginPrivateCheck(); return }
        guard updater.canCheckForUpdates else { return }
        updater.checkForUpdates()
    }

    private func beginPrivateCheck(installRequested: Bool = false) {
        guard let repository = githubRepository, let updater,
              (installRequested ? installIntent == .refreshing : !isBusy && phase != .available),
              !updater.sessionInProgress else { return }
        do {
            guard let token = try GitHubUpdateCredentials.read(repository: repository) else {
                installIntent = .none
                cancellation = nil
                requiresGitHubConnection = true
                phase = .idle
                message = "Connect GitHub once on this Mac to receive private updates. Use a fine-grained token with Contents: Read-only for \(repository)."
                return
            }
            requiresGitHubConnection = false
            let source = try GitHubUpdateSource(repository: repository)
            phase = .checking
            message = "Checking private releases…"
            cancellation = { [weak self] in self?.discoveryTask?.cancel(); self?.discoveryTask = nil }
            discoveryTask = Task { [weak self, weak updater] in
                do {
                    let feed = try await source.latestFeed(token: token)
                    try Task.checkCancellation()
                    guard let self, let updater else { return }
                    self.discoveryTask = nil
                    self.cancellation = nil
                    // The feed is a short-lived GitHub CDN URL. Never attach
                    // a repository credential to that request.
                    updater.httpHeaders = nil
                    self.archiveToken = token
                    self.resolvedFeedURL = feed
                    // Our user driver never opens an unsolicited window. This
                    // entry point avoids interfering with Sparkle's scheduler.
                    updater.checkForUpdates()
                } catch is CancellationError {
                    // Cancellation already updates the UI; don't overwrite a retry.
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.discoveryTask = nil
                    self?.presentFailure(error)
                }
            }
        } catch { presentFailure(error) }
    }

    func connectGitHub(token: String) {
        guard let repository = githubRepository, !isBusy else { return }
        do {
            try GitHubUpdateCredentials.save(token: token, repository: repository)
            requiresGitHubConnection = false
            phase = .idle
            beginPrivateCheck()
        } catch { presentFailure(error) }
    }

    func disconnectGitHub() {
        guard let repository = githubRepository, !isBusy else { return }
        do {
            try GitHubUpdateCredentials.remove(repository: repository)
            let reply = choice
            choice = nil
            reply?(.dismiss)
            updater?.httpHeaders = nil
            resolvedFeedURL = nil
            archiveToken = nil
            requiresGitHubConnection = true
            phase = .idle
            message = "GitHub disconnected on this Mac. Existing recordings are still available."
        } catch { presentFailure(error) }
    }

    func retryRelaunch() {
        guard canRetryRestart, !recordingIsActive() else { return }
        retryRestart?()
    }

    func installUpdate() {
        guard canInstall, let reply = choice else { return }
        choice = nil
        userAuthorizedInstallation = false
        installIntent = .waitingForDismissal
        phase = .checking
        progress = nil
        message = "Checking for the latest version before updating…"
        cancellation = { [weak self] in self?.stopObservingRefreshReadiness() }
        // Release the earlier SDK offer so a release published since the icon
        // appeared can replace it. This does not authorize the earlier archive.
        reply(.dismiss)
    }

    // The SDK's finish callback and deterministic tests share this transition.
    // A finish callback from an unrelated check cannot grant installation consent.
    func finishOfferedUpdateCycle(error: Error?) -> Bool {
        guard installIntent == .waitingForDismissal else { return false }
        if let error { presentFailure(error); return false }
        installIntent = .refreshing
        awaitingRefreshReadiness = true
        return true
    }

    // Consume readiness once. SDK scheduling can temporarily reactivate a
    // session after its finish delegate callback, so elapsed turns are not a
    // reliable indication that a new check can start.
    func claimInstallRefreshReadiness(sessionInProgress: Bool, canCheckForUpdates: Bool) -> Bool {
        guard installIntent == .refreshing, awaitingRefreshReadiness,
              !sessionInProgress, canCheckForUpdates else { return false }
        awaitingRefreshReadiness = false
        return true
    }

    private func observeRefreshReadiness() {
        guard installIntent == .refreshing, let updater else { return }
        let changed: @Sendable (SPUUpdater, NSKeyValueObservedChange<Bool>) -> Void = { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refreshForInstallation() }
        }
        // Both properties are KVO-backed by Sparkle. Register before reading
        // their current values so a readiness transition cannot be missed.
        refreshReadinessObservations = [
            updater.observe(\.sessionInProgress, options: [.new], changeHandler: changed),
            updater.observe(\.canCheckForUpdates, options: [.new], changeHandler: changed)
        ]
        refreshForInstallation()
    }

    private func stopObservingRefreshReadiness() {
        awaitingRefreshReadiness = false
        refreshReadinessObservations.removeAll()
        installRefreshTask?.cancel()
        installRefreshTask = nil
    }

    private func refreshForInstallation() {
        guard installIntent == .refreshing else { return }
        guard !recordingIsActive(), let updater else {
            presentFailure(NSError(domain: "ScholarsEye.Update", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The update check could not start. Finish recording or syncing and try again."]))
            return
        }
        guard claimInstallRefreshReadiness(sessionInProgress: updater.sessionInProgress,
                                          canCheckForUpdates: updater.canCheckForUpdates) else { return }
        stopObservingRefreshReadiness()
        if githubRepository != nil { beginPrivateCheck(installRequested: true) }
        else { updater.checkForUpdates() }
    }

    private func downloadOfferedUpdate() {
        guard canInstall, let reply = choice else { return }
        choice = nil
        userAuthorizedInstallation = true
        phase = .downloading
        progress = nil
        message = "Downloading a verified update. ScholarsEye will restart when it’s ready."
        reply(.install)
    }

    func cancel() {
        guard let cancellation else { return }
        self.cancellation = nil
        installIntent = .none
        userAuthorizedInstallation = false
        cancellation()
        phase = .idle
        progress = nil
        message = "Update cancelled. Your current app is unchanged."
    }

    func show(_ request: SPUUpdatePermissionRequest,
                                     reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // The app's declared policy enables checks, never unattended installs or telemetry.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, automaticUpdateDownloading: false, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        phase = .checking
        message = "Checking for a newer release…"
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        cancellation = nil
        userAuthorizedInstallation = false
        availableVersion = String(appcastItem.displayVersionString.prefix(60))
        releaseNotes = Self.plainNotes(appcastItem.itemDescription ?? "")
        if appcastItem.isInformationOnlyUpdate {
            installIntent = .none
            phase = .failed
            message = "Version \(availableVersion ?? "") requires a manual installation. Check the project’s releases."
            reply(.dismiss)
            return
        }
        if let repository = githubRepository,
           appcastItem.fileURL.map({ isTrustedAssetURL($0, repository: repository) }) != true {
            installIntent = .none
            phase = .failed
            message = "The update download does not belong to the configured private repository."
            reply(.dismiss)
            return
        }
        offerUpdate(version: availableVersion ?? "", notes: releaseNotes, reply: reply)
    }

    // Kept separate from the SDK callback so recording/install race guards can
    // be tested without a live release server or fake Sparkle state objects.
    func offerUpdate(version: String, notes: String, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let installRequested = installIntent == .refreshing
        stopObservingRefreshReadiness()
        installIntent = .none
        userAuthorizedInstallation = false
        cancellation = nil
        availableVersion = String(version.prefix(60))
        releaseNotes = notes
        choice = reply
        phase = .available
        progress = nil
        message = "Installs version \(availableVersion ?? "") and restarts ScholarsEye. Your recordings stay in place."
        if installRequested { downloadOfferedUpdate() }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        releaseNotes = Self.plainNotes(String(data: downloadData.data, encoding: .utf8) ?? "")
    }
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        stopObservingRefreshReadiness()
        installIntent = .none
        choice = nil
        cancellation = nil
        phase = .current
        message = (error as NSError).localizedRecoverySuggestion ?? "You’re running the latest compatible version."
        availableVersion = nil
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        presentFailure(error)
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        received = 0
        expected = 0
        progress = nil
        phase = .downloading
    }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expected = expectedContentLength
        updateDownloadProgress()
    }
    func showDownloadDidReceiveData(ofLength length: UInt64) {
        let (sum, overflow) = received.addingReportingOverflow(length)
        received = overflow ? UInt64.max : sum
        updateDownloadProgress()
    }
    private func updateDownloadProgress() {
        progress = expected > 0 ? min(Double(received) / Double(expected), 1) : nil
    }
    func showDownloadDidStartExtractingUpdate() {
        cancellation = nil
        phase = .extracting
        progress = nil
        message = "Verifying and preparing the update…"
    }
    func showExtractionReceivedProgress(_ progress: Double) {
        self.progress = progress.isFinite ? min(max(progress, 0), 1) : nil
    }
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard userAuthorizedInstallation, !recordingIsActive() else {
            reply(.skip)
            phase = .failed
            message = "Finish recording or syncing before installing an update."
            return
        }
        phase = .installing
        message = "Installing and restarting…"
        reply(.install)
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        phase = .installing
        message = "Installing and restarting…"
        canRetryRestart = !applicationTerminated
        retryRestart = applicationTerminated ? nil : retryTerminatingApplication
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        phase = .current
        message = "Update installed."
        acknowledgement()
    }
    func dismissUpdateInstallation() {
        choice = nil
        // Dismissing the stale offer precedes didFinishUpdateCycle. Keep only
        // the user's pending fresh check alive across that expected callback.
        if installIntent == .waitingForDismissal { return }
        stopObservingRefreshReadiness()
        installIntent = .none
        cancellation = nil
        progress = nil
        userAuthorizedInstallation = false
        canRetryRestart = false
        retryRestart = nil
        if [.checking, .downloading, .extracting, .installing].contains(phase) { phase = .idle }
    }
    func showUpdateInFocus() { showDetails = true }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let nsError = error as NSError
        if nsError.domain == SUSparkleErrorDomain && nsError.code == 1001 { return }
        presentFailure(error)
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        guard finishOfferedUpdateCycle(error: error) else { return }
        installRefreshTask = Task { @MainActor [weak self] in
            // Observe the SDK's actual readiness after the callback returns;
            // its asynchronous scheduling work can keep the session active.
            guard !Task.isCancelled else { return }
            self?.installRefreshTask = nil
            self?.observeRefreshReadiness()
        }
    }

    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate updateItem: SUAppcastItem) -> Bool {
        // Notes embedded in the signed feed are sufficient. Never attach a
        // private repository credential to an arbitrary release-notes URL.
        false
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem,
                 with request: NSMutableURLRequest) {
        guard let repository = githubRepository, let token = archiveToken,
              let url = request.url, isTrustedAssetURL(url, repository: repository),
              let headers = try? GitHubUpdateSource.archiveRequestHeaders(token: token) else { return }
        // Only the configured repository's archive API receives authorization.
        // URLSession strips it when GitHub redirects to its download CDN.
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
    }

    func feedURLString(for updater: SPUUpdater) -> String? { resolvedFeedURL?.absoluteString }

    private func presentFailure(_ error: Error) {
        installIntent = .none
        stopObservingRefreshReadiness()
        phase = .failed
        progress = nil
        choice = nil
        cancellation = nil
        userAuthorizedInstallation = false
        canRetryRestart = false
        retryRestart = nil
        message = "\(error.localizedDescription) Your recordings are stored separately from the app."
    }

    private static func plainNotes(_ text: String) -> String {
        // Never render downloaded HTML or execute links/scripts in the updater UI.
        String(text.prefix(16_000)).replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct UpdateStatusView: View {
    @ObservedObject var updates: UpdateController
    let recording: Bool
    var syncing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var token = ""
    @State private var hovering = false

    private var updateAvailable: Bool { updates.phase == .available }
    private var tooltip: String {
        if updateAvailable {
            if syncing { return "Update available. Finish or cancel syncing, then click to update." }
            return recording ? "Update available. Stop and save your recording, then click to update."
                : "Update to \(updates.availableVersion ?? "the latest version") and restart"
        }
        return updates.isBusy ? updates.buttonTitle : updates.message
    }

    private var tokenCreationURL: URL {
        var components = URLComponents(string: "https://github.com/settings/personal-access-tokens/new")!
        components.queryItems = [URLQueryItem(name: "name", value: "ScholarsEye updates"),
                                URLQueryItem(name: "contents", value: "read")]
        if let owner = updates.githubRepository?.split(separator: "/").first {
            components.queryItems?.append(URLQueryItem(name: "target_name", value: String(owner)))
        }
        return components.url!
    }

    var body: some View {
        Button {
            if updateAvailable && !recording && !syncing { updates.installUpdate() }
            else if syncing { updates.showDetails = true }
            else { updates.checkForUpdates() }
        } label: {
            ZStack {
                Circle().fill(updateAvailable ? Color(red: 1, green: 0.86, blue: 0.46)
                              : Color.black.opacity(hovering ? 0.075 : 0.035))
                if updates.isBusy {
                    ProgressView().controlSize(.small).scaleEffect(0.75)
                } else {
                    Image(systemName: updateAvailable ? "arrow.up" : updates.phase == .failed ? "exclamationmark" : "arrow.triangle.2.circlepath")
                        .font(.system(size: 13, weight: updateAvailable ? .bold : .medium))
                        .foregroundStyle(updateAvailable ? Color(red: 0.37, green: 0.25, blue: 0.06) : Color.secondary)
                }
            }
            .frame(width: 30, height: 30).contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(updateAvailable ? "Update to \(updates.availableVersion ?? "latest") and restart" : updates.buttonTitle)
        .help(tooltip)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: updateAvailable)
        .contextMenu {
            Button("Update details…") { updates.showDetails = true }
        }
        .popover(isPresented: $updates.showDetails, arrowEdge: .leading) {
            VStack(alignment: .leading, spacing: 12) {
                Text("ScholarsEye \(updates.currentVersion)").font(.headline)
                Text(updates.message).fixedSize(horizontal: false, vertical: true)
                if updates.githubRepository != nil, updates.configured, !updates.isBusy {
                    if updates.requiresGitHubConnection || updates.phase == .failed {
                        Link("Create a GitHub token ↗", destination: tokenCreationURL)
                        Text("Select only ScholarsEye, then set Contents to Read-only.")
                            .font(.caption).foregroundStyle(.secondary)
                        SecureField("Read-only GitHub token", text: $token)
                            .textContentType(.password).textFieldStyle(.roundedBorder)
                        Button("Connect GitHub") {
                            updates.connectGitHub(token: token)
                            token = ""
                        }.disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Text("Stored only in this Mac’s Keychain.").font(.caption).foregroundStyle(.secondary)
                    }
                    if !updates.requiresGitHubConnection {
                        Button("Disconnect GitHub on this Mac") { updates.disconnectGitHub() }
                    }
                }
                if updates.phase == .available && recording {
                    Text("Stop and save your recording before updating.").foregroundStyle(.secondary)
                }
                if syncing {
                    Text("Finish or cancel syncing before updating.").foregroundStyle(.secondary)
                }
                if !updates.releaseNotes.isEmpty {
                    ScrollView { Text(updates.releaseNotes).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                        .frame(maxHeight: 160)
                }
                if let progress = updates.progress { ProgressView(value: progress) }
                if updates.phase == .available {
                    Button("Update & restart") { updates.installUpdate() }
                        .disabled(recording || syncing || !updates.canInstall)
                } else if updates.canCancel {
                    Button("Cancel update") { updates.cancel() }
                } else if updates.canRetryRestart {
                    Button("Restart now") { updates.retryRelaunch() }.disabled(recording || syncing)
                } else if updates.configured && !updates.isBusy && !updates.requiresGitHubConnection {
                    Button("Check again") { updates.checkForUpdates() }
                }
            }.font(.system(size: 12)).padding(20).frame(width: 310)
                .onDisappear { token = "" }
        }
    }
}
