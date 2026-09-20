import Foundation

struct SessionDayGroup: Identifiable {
    let day: Date
    let title: String
    let sessions: [RecordingSession]
    var id: Date { day }
}

enum SessionLibraryError: LocalizedError, Equatable {
    case captureInProgress, analysisInProgress, syncInProgress, sessionMissing, unsafeLocation, invalidManifest, identityChanged

    var errorDescription: String? {
        switch self {
        case .captureInProgress: return "Stop and save your recording before moving a session to Trash."
        case .analysisInProgress: return "Wait for this session's analysis to finish before moving it to Trash."
        case .syncInProgress: return "Finish or cancel syncing before moving a session to Trash."
        case .sessionMissing: return "This session is no longer in the library. Refresh and try again."
        case .unsafeLocation: return "Only session folders directly inside the recording library can be moved to Trash. Linked folders are not supported."
        case .invalidManifest: return "The session information is missing or unreadable. Its files have not been moved."
        case .identityChanged: return "This session changed on disk. Refresh the library and try again."
        }
    }
}

enum SessionLibrary {
    static func groups(for sessions: [RecordingSession], now: Date = Date(), calendar: Calendar = .current) -> [SessionDayGroup] {
        let today = calendar.startOfDay(for: now)
        let grouped = Dictionary(grouping: sessions) { calendar.startOfDay(for: $0.startedAt) }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? .current
        return grouped.keys.sorted(by: >).map { day in
            let age = calendar.dateComponents([.day], from: day, to: today).day
            let title: String
            if age == 0 {
                title = "Today"
            } else if let age, (1...6).contains(age) {
                title = "\(age)d ago"
            } else {
                let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: today)
                formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMM d" : "MMM d yyyy")
                title = formatter.string(from: day)
            }
            let rows = (grouped[day] ?? []).sorted {
                $0.startedAt == $1.startedAt ? $0.id > $1.id : $0.startedAt > $1.startedAt
            }
            return SessionDayGroup(day: day, title: title, sessions: rows)
        }
    }

    /// Validates the on-disk identity and boundary immediately before handing
    /// the folder to macOS Trash. Tests inject an action instead of moving files.
    static func trash(_ session: RecordingSession, storageURL: URL,
                      fileManager: FileManager = .default,
                      trashAction: ((URL) throws -> Void)? = nil) throws {
        let target = try validatedTrashURL(session, storageURL: storageURL, fileManager: fileManager)
        if let trashAction { try trashAction(target) }
        else { try fileManager.trashItem(at: target, resultingItemURL: nil) }
    }

    private static func validatedTrashURL(_ session: RecordingSession, storageURL: URL,
                                          fileManager: FileManager) throws -> URL {
        guard storageURL.isFileURL, session.url.isFileURL,
              !session.url.pathComponents.contains(".."), !session.url.pathComponents.contains(".") else {
            throw SessionLibraryError.unsafeLocation
        }
        let root = storageURL.standardizedFileURL.resolvingSymlinksInPath()
        let supplied = session.url.standardizedFileURL
        let target = supplied.resolvingSymlinksInPath()
        guard root.path != target.path,
              supplied.deletingLastPathComponent().resolvingSymlinksInPath().path == root.path,
              target.deletingLastPathComponent().path == root.path,
              (try? fileManager.attributesOfItem(atPath: root.path)[.type] as? FileAttributeType) == .typeDirectory,
              (try? fileManager.attributesOfItem(atPath: supplied.path)[.type] as? FileAttributeType) == .typeDirectory,
              (try? fileManager.attributesOfItem(atPath: target.path)[.type] as? FileAttributeType) == .typeDirectory else {
            // Requiring the supplied entry itself to be a directory rejects
            // symlinks even when their destination happens to be another session.
            throw SessionLibraryError.unsafeLocation
        }
        let manifest = target.appendingPathComponent("manifest.json")
        guard manifest.resolvingSymlinksInPath().path == manifest.path,
              (try? fileManager.attributesOfItem(atPath: manifest.path)[.type] as? FileAttributeType) == .typeRegular,
              let data = try? Data(contentsOf: manifest),
              let saved = try? RecordingSession.decoder().decode(RecordingSession.self, from: data) else {
            throw SessionLibraryError.invalidManifest
        }
        guard saved.id == session.id else { throw SessionLibraryError.identityChanged }
        return target
    }
}
