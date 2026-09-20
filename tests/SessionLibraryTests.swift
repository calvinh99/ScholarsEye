import Foundation

private enum Failure: Error, CustomStringConvertible {
    case failed(String)
    var description: String { switch self { case .failed(let message): return message } }
}
private func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw Failure.failed(message) }
}

@main
struct SessionLibraryTests {
    static let manager = FileManager.default

    static func main() {
        do {
            try dayGrouping()
            try calendarBoundaries()
            try safeTrashBoundaries()
            print("PASS: local day/row order, Today and relative/date headers, timezone and DST boundaries, immediate-child trash validation, manifest identity, symlink/root/traversal rejection, and propagated trash failure; no actual Trash operation")
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }

    static func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    static func calendar(_ zone: String = "America/Los_Angeles") -> Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: zone)!
        result.locale = Locale(identifier: "en_US")
        return result
    }
    static func session(_ id: String, _ startedAt: Date = Date(), url: URL = URL(fileURLWithPath: "/")) -> RecordingSession {
        RecordingSession(id: id, startedAt: startedAt, status: "complete", configuration: CaptureConfiguration(),
                         displayID: 1, displayWidth: 640, displayHeight: 360, url: url)
    }

    static func dayGrouping() throws {
        let now = date("2026-09-20T19:00:00Z")
        let rows = [session("old", date("2025-09-20T19:00:00Z")),
                    session("early", date("2026-09-20T07:10:00Z")),
                    session("yesterday", date("2026-09-20T06:59:00Z")),
                    session("late", date("2026-09-20T18:10:00Z")),
                    session("six", date("2026-09-14T19:00:00Z")),
                    session("seven", date("2026-09-13T19:00:00Z"))]
        let groups = SessionLibrary.groups(for: rows, now: now, calendar: calendar())
        try require(groups.map(\.title) == ["Today", "1d ago", "6d ago", "Sep 13", "Sep 20, 2025"], "Headers must use calendar age through six days, then abbreviated dates and necessary years")
        try require(groups.first?.sessions.map(\.id) == ["late", "early"], "Sessions within a day are newest first")
        try require(groups.map(\.day) == groups.map(\.day).sorted(by: >), "Groups are newest first")
        try require(groups.allSatisfy { $0.day == calendar().startOfDay(for: $0.day) && $0.id == $0.day }, "Group identity is the local start of day")
        try require(SessionLibrary.groups(for: [], now: now, calendar: calendar()).isEmpty, "An empty library has no empty headers")
        let future = SessionLibrary.groups(for: [session("future", date("2026-09-21T19:00:00Z"))], now: now, calendar: calendar())
        try require(future.first?.title == "Sep 21", "Future clock skew does not produce a negative relative age")
        let ties = SessionLibrary.groups(for: [session("a", now), session("b", now)], now: now, calendar: calendar())
        try require(ties.first?.sessions.map(\.id) == ["b", "a"], "Equal timestamps have deterministic row order")
    }

    static func calendarBoundaries() throws {
        for (current, previous, interval) in [
            ("2026-03-09T07:30:00Z", "2026-03-08T08:30:00Z", 23.0),
            ("2026-11-02T08:30:00Z", "2026-11-01T07:30:00Z", 25.0)
        ] {
            let now = date(current), before = date(previous)
            try require(now.timeIntervalSince(before) == interval * 3600, "DST fixture spans the expected short/long day")
            let groups = SessionLibrary.groups(for: [session("before", before)], now: now, calendar: calendar())
            try require(groups.first?.title == "1d ago", "DST day boundaries must not be derived by dividing seconds by 86400")
        }
        let row = session("boundary", date("2026-09-20T02:00:00Z"))
        let now = date("2026-09-20T19:00:00Z")
        try require(SessionLibrary.groups(for: [row], now: now, calendar: calendar()).first?.title == "1d ago", "Grouping uses the supplied local timezone")
        try require(SessionLibrary.groups(for: [row], now: now, calendar: calendar("UTC")).first?.title == "Today", "The same instant can belong to today's UTC group")
    }

    static func safeTrashBoundaries() throws {
        let temporary = manager.temporaryDirectory.appendingPathComponent("ScholarsEyeLibrary-" + UUID().uuidString)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("recordings")
        let outside = temporary.appendingPathComponent("outside")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        let folder = root.appendingPathComponent("session-one")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let one = session("session-one", url: folder)
        try one.save()
        let bytesBefore = try Data(contentsOf: folder.appendingPathComponent("manifest.json"))
        var targets: [URL] = []
        try SessionLibrary.trash(one, storageURL: root) { targets.append($0) }
        try require(targets == [folder.resolvingSymlinksInPath()], "A validated session invokes the injected Trash action exactly once")
        try require(manager.fileExists(atPath: folder.path), "Injected validation must never move real files")

        func rejected(_ candidate: RecordingSession, expected: SessionLibraryError, storage: URL? = nil) throws {
            var called = false
            do {
                try SessionLibrary.trash(candidate, storageURL: storage ?? root) { _ in called = true }
            } catch let error as SessionLibraryError {
                try require(error == expected && !called, "Unsafe candidates must fail before invoking Trash")
                return
            }
            throw Failure.failed("Unsafe candidate was accepted")
        }
        try rejected(session("root", url: root), expected: .unsafeLocation)
        try rejected(session("outside", url: outside), expected: .unsafeLocation)
        try rejected(session("outside", url: URL(fileURLWithPath: root.path + "/../outside")), expected: .unsafeLocation)
        let nested = folder.appendingPathComponent("nested")
        try manager.createDirectory(at: nested, withIntermediateDirectories: true)
        try rejected(session("nested", url: nested), expected: .unsafeLocation)
        try rejected(session("missing", url: root.appendingPathComponent("missing")), expected: .unsafeLocation)
        try rejected(session("remote", url: URL(string: "https://example.com/session")!), expected: .unsafeLocation)
        try rejected(one, expected: .unsafeLocation, storage: URL(string: "https://example.com/library")!)
        let prefixSibling = temporary.appendingPathComponent("recordings-other")
        try manager.createDirectory(at: prefixSibling, withIntermediateDirectories: true)
        try rejected(session("prefix", url: prefixSibling), expected: .unsafeLocation)

        // Every linked candidate has the expected manifest identity, so boundary
        // checks, not a coincidental ID mismatch, must reject it.
        try session("external", url: outside).save()
        try session("root", url: root).save()
        for (name, destination, identity) in [("linked-out", outside, "external"),
                                               ("linked-root", root, "root"),
                                               ("linked-sibling", folder, "session-one")] {
            let link = root.appendingPathComponent(name)
            try manager.createSymbolicLink(at: link, withDestinationURL: destination)
            try rejected(session(identity, url: link), expected: .unsafeLocation)
        }
        try rejected(session("different-id", url: folder), expected: .identityChanged)
        let malformed = root.appendingPathComponent("malformed")
        try manager.createDirectory(at: malformed, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: malformed.appendingPathComponent("manifest.json"))
        try rejected(session("malformed", url: malformed), expected: .invalidManifest)
        let linkedManifest = root.appendingPathComponent("linked-manifest")
        try manager.createDirectory(at: linkedManifest, withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: linkedManifest.appendingPathComponent("manifest.json"), withDestinationURL: outside.appendingPathComponent("manifest.json"))
        try rejected(session("external", url: linkedManifest), expected: .invalidManifest)

        let linkedRoot = temporary.appendingPathComponent("configured-library-link")
        try manager.createSymbolicLink(at: linkedRoot, withDestinationURL: root)
        var throughRoot = one
        throughRoot.url = linkedRoot.appendingPathComponent("session-one")
        try SessionLibrary.trash(throughRoot, storageURL: linkedRoot) { target in
            try require(target == folder.resolvingSymlinksInPath(), "A configured library symlink resolves to its own direct child")
        }
        var failureReached = false
        do {
            try SessionLibrary.trash(one, storageURL: root) { _ in
                failureReached = true
                throw CocoaError(.fileWriteNoPermission)
            }
            throw Failure.failed("Trash failure was swallowed")
        } catch let error as CocoaError {
            try require(failureReached && error.code == .fileWriteNoPermission, "Recoverable Trash errors must propagate to the UI")
        }
        let bytesAfter = try Data(contentsOf: folder.appendingPathComponent("manifest.json"))
        try require(bytesAfter == bytesBefore, "Validation and failed Trash never rewrite the session")
    }
}
