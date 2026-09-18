import Foundation

private enum Failure: Error { case failed(String) }
private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw Failure.failed(message) }
}
private func close(_ value: Double?, _ expected: Double) -> Bool {
    value.map { abs($0 - expected) < 0.000_001 } ?? false
}
private func reading(_ cpu: Double, _ ram: Int64) -> ProcessResourceReading {
    ProcessResourceReading(cpuSeconds: cpu, residentBytes: ram)
}

@main
struct RecordingDiagnosticsTests {
    static func main() async throws {
        var accumulator = RecordingDiagnosticsAccumulator(sessionID: "weighted")
        accumulator.begin(reading: reading(7, 100), at: 100)
        accumulator.sample(reading: reading(7.5, 300), at: 105)
        accumulator.sample(reading: reading(9.5, 500), at: 115)
        try require(close(accumulator.snapshot.currentCPUPercent, 20), "CPU is elapsed CPU / wall seconds, 100 percent per core")
        try require(close(accumulator.snapshot.averageCPUPercent, 100 * 2.5 / 15), "Unequal intervals use duration-weighted CPU")
        try require(close(accumulator.snapshot.averageResidentBytes, 5000 / 15), "RAM uses time-weighted trapezoidal samples")
        accumulator.endSegment()
        accumulator.begin(reading: reading(30, 1000), at: 999)
        accumulator.sample(reading: reading(30.25, 1000), at: 1004)
        try require(close(accumulator.snapshot.activeDurationSeconds, 20), "Pause duration excluded")
        try require(close(accumulator.snapshot.averageCPUPercent, 13.75), "CPU used during pause excluded")
        try require(close(accumulator.snapshot.averageResidentBytes, 500), "No memory interval interpolates across pause")
        accumulator.sample(reading: nil, at: 1009, error: "Injected missing measurement")
        try require(accumulator.snapshot.currentCPUPercent == nil && accumulator.snapshot.currentResidentBytes == nil, "Missing measurement is unavailable, never zero")
        accumulator.sample(reading: reading(30.5, 1200), at: 1014)
        try require(close(accumulator.snapshot.sampledActiveSeconds, 20), "Unknown intervals excluded from average denominator")
        accumulator.sample(reading: reading(31.5, 1200), at: 1019)
        try require(close(accumulator.snapshot.sampledActiveSeconds, 25), "Measurement coverage resumes from new baseline")
        try require(close(accumulator.snapshot.averageCPUPercent, 15), "Missing samples cannot dilute CPU average")
        try require(close(accumulator.snapshot.averageResidentBytes, 640), "Weighted RAM excludes unavailable intervals")
        try require(accumulator.snapshot.measurementFailures == 1, "Measurement failure remains visible")

        var long = RecordingDiagnosticsAccumulator(sessionID: "long")
        long.begin(reading: reading(0, 128_000_000), at: 0)
        for index in 1...10_000 {
            long.sample(reading: reading(Double(index) * 0.5, 128_000_000), at: Double(index) * 5)
        }
        try require(long.snapshot.samples.count <= 240, "Thirteen-hour chart memory stays bounded")
        try require(close(long.snapshot.averageCPUPercent, 10), "Downsampling preserves complete weighted aggregate")
        try require(long.snapshot.totalSamples == 10_001, "Original measurement count survives downsampling")
        try require(long.snapshot.samples.first?.elapsedActiveSeconds == 0 && long.snapshot.samples.last?.elapsedActiveSeconds == 50_000, "Chart retains first and latest measurements")
        try require(zip(long.snapshot.samples, long.snapshot.samples.dropFirst()).allSatisfy { $0.elapsedActiveSeconds < $1.elapsedActiveSeconds }, "Chart remains chronological")

        let before = try ProcessResourceProbe.read()
        var value = 0.0
        for index in 1...250_000 { value += Double(index).squareRoot() }
        let after = try ProcessResourceProbe.read()
        try require(value > 0 && after.cpuSeconds > before.cpuSeconds && after.residentBytes > 0, "Native probe returns measured own-process CPU and resident memory")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ScholarsEyeDiagnosticsTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try require(RecordingDiagnosticsSnapshot.load(from: folder) == nil, "Older sessions have no invented measurements")
        let sampler = RecordingDiagnosticsSampler(sessionID: "saved", folder: folder, onUpdate: { _ in })
        _ = await sampler.resume()
        try await Task.sleep(nanoseconds: 20_000_000)
        let final = await sampler.pause()
        let saved = RecordingDiagnosticsSnapshot.load(from: folder)
        try require(saved?.sessionID == "saved" && saved?.totalSamples == final.totalSamples, "Pause returns after final diagnostics are persisted")
        try require((saved?.sampledActiveSeconds ?? 0) > 0 && saved?.averageCPUPercent != nil, "Short recordings receive a final measured interval")
        let failedSampler = RecordingDiagnosticsSampler(sessionID: "no-folder", folder: folder.appendingPathComponent("missing"), onUpdate: { _ in })
        let failure = await failedSampler.resume()
        try require(failure.persistenceError != nil, "Write errors surface without stopping capture")
        _ = await failedSampler.pause()
        print("PASS: weighted CPU/RAM, pause exclusion, unavailable measurements, bounded long-session charts, native counters, atomic final persistence, old sessions, and write failure")
    }
}
