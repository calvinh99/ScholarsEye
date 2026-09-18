import Darwin
import Foundation

struct RecordingDiagnosticSample: Codable, Identifiable {
    let elapsedActiveSeconds: Double
    let cpuPercent: Double?
    let residentBytes: Int64?
    var id: Double { elapsedActiveSeconds }
}

struct RecordingDiagnosticsSnapshot: Codable {
    var schemaVersion = 1
    let sessionID: String
    var updatedAt = Date()
    var sampleIntervalSeconds: Double = 5
    var activeDurationSeconds: Double = 0
    var sampledActiveSeconds: Double = 0
    var currentCPUPercent: Double?
    var averageCPUPercent: Double?
    var peakCPUPercent: Double?
    var currentResidentBytes: Int64?
    var averageResidentBytes: Double?
    var peakResidentBytes: Int64?
    var totalSamples = 0
    var measurementFailures = 0
    var lastError: String?
    var persistenceError: String?
    var samples: [RecordingDiagnosticSample] = []

    static func load(from folder: URL) -> Self? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("diagnostics.json")) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let result = try? decoder.decode(Self.self, from: data), result.schemaVersion == 1 else { return nil }
        return result
    }
}

struct ProcessResourceReading {
    let cpuSeconds: Double
    let residentBytes: Int64
}

enum ProcessResourceProbe {
    static func read() throws -> ProcessResourceReading {
        // getrusage includes all live and exited threads of this process only.
        // timeval exposes seconds/microseconds, avoiding Mach timebase guesses.
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var memory = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &memory) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS, memory.resident_size <= UInt64(Int64.max) else {
            throw NSError(domain: "ScholarsEye.ProcessMemory", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Process resident memory is unavailable (\(status))."])
        }
        let cpu = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return ProcessResourceReading(cpuSeconds: cpu, residentBytes: Int64(memory.resident_size))
    }
}

// The aggregate keeps exact weighted totals independently of the bounded chart.
// Missing reads break the baseline rather than inventing CPU or RAM measurements.
struct RecordingDiagnosticsAccumulator {
    private(set) var snapshot: RecordingDiagnosticsSnapshot
    private var previous: ProcessResourceReading?
    private var previousTime: Double?
    private var totalCPUSeconds: Double = 0
    private var residentByteSeconds: Double = 0
    private let maximumChartSamples = 240

    init(sessionID: String) { snapshot = RecordingDiagnosticsSnapshot(sessionID: sessionID) }

    mutating func begin(reading: ProcessResourceReading?, at time: Double, error: String? = nil) {
        previous = reading
        previousTime = time
        snapshot.currentCPUPercent = nil
        acceptCurrent(reading, error: error)
        appendChartPoint()
    }

    mutating func sample(reading: ProcessResourceReading?, at time: Double, error: String? = nil) {
        guard let previousTime, time.isFinite, time > previousTime else { return }
        let elapsed = time - previousTime
        snapshot.activeDurationSeconds += elapsed
        snapshot.currentCPUPercent = nil
        if let reading, let previous, reading.cpuSeconds >= previous.cpuSeconds {
            let cpu = reading.cpuSeconds - previous.cpuSeconds
            let percent = cpu / elapsed * 100
            totalCPUSeconds += cpu
            residentByteSeconds += (Double(previous.residentBytes) + Double(reading.residentBytes)) * 0.5 * elapsed
            snapshot.sampledActiveSeconds += elapsed
            snapshot.currentCPUPercent = percent
            snapshot.averageCPUPercent = totalCPUSeconds / snapshot.sampledActiveSeconds * 100
            snapshot.peakCPUPercent = max(snapshot.peakCPUPercent ?? percent, percent)
            snapshot.averageResidentBytes = residentByteSeconds / snapshot.sampledActiveSeconds
        } else if reading != nil, previous != nil {
            snapshot.measurementFailures += 1
            snapshot.lastError = "Process CPU counters moved backwards; this interval is unavailable."
        }
        self.previous = reading
        self.previousTime = time
        acceptCurrent(reading, error: error)
        appendChartPoint()
    }

    mutating func endSegment() {
        previous = nil
        previousTime = nil
    }

    mutating func setPersistenceError(_ message: String?) { snapshot.persistenceError = message }

    private mutating func acceptCurrent(_ reading: ProcessResourceReading?, error: String?) {
        snapshot.updatedAt = Date()
        snapshot.totalSamples += 1
        snapshot.currentResidentBytes = reading?.residentBytes
        if let reading {
            snapshot.peakResidentBytes = max(snapshot.peakResidentBytes ?? reading.residentBytes, reading.residentBytes)
        } else {
            snapshot.measurementFailures += 1
            snapshot.lastError = error ?? "Process resource measurement is unavailable."
        }
    }

    private mutating func appendChartPoint() {
        let point = RecordingDiagnosticSample(elapsedActiveSeconds: snapshot.activeDurationSeconds,
            cpuPercent: snapshot.currentCPUPercent, residentBytes: snapshot.currentResidentBytes)
        // Resume shares the previous endpoint's active-time coordinate. Keep the
        // new baseline there, with no synthetic interval spanning the pause.
        if snapshot.samples.last?.elapsedActiveSeconds == point.elapsedActiveSeconds {
            snapshot.samples[snapshot.samples.count - 1] = point
        } else { snapshot.samples.append(point) }
        if snapshot.samples.count > maximumChartSamples {
            let last = snapshot.samples.count - 1
            snapshot.samples = snapshot.samples.enumerated().compactMap { index, point in
                index.isMultiple(of: 2) || index == last ? point : nil
            }
        }
    }
}

// A separate utility queue owns sampling, JSON encoding, and atomic disk writes.
// No diagnostic syscalls, encoding, or file I/O run on the capture callback queue.
final class RecordingDiagnosticsSampler: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.scholarseye.diagnostics", qos: .utility)
    private let folder: URL
    private let onUpdate: (RecordingDiagnosticsSnapshot) -> Void
    private var accumulator: RecordingDiagnosticsAccumulator
    private var timer: DispatchSourceTimer?

    init(sessionID: String, folder: URL, onUpdate: @escaping (RecordingDiagnosticsSnapshot) -> Void) {
        self.folder = folder
        self.onUpdate = onUpdate
        accumulator = RecordingDiagnosticsAccumulator(sessionID: sessionID)
    }

    func resume() async -> RecordingDiagnosticsSnapshot {
        await withCheckedContinuation { continuation in
            queue.async {
                if self.timer == nil {
                    self.measure(isBaseline: true)
                    let timer = DispatchSource.makeTimerSource(queue: self.queue)
                    timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .milliseconds(500))
                    timer.setEventHandler { [weak self] in
                        guard let self, self.timer != nil else { return }
                        self.measure(isBaseline: false)
                        self.persistAndPublish()
                    }
                    self.timer = timer
                    timer.resume()
                }
                self.persistAndPublish()
                continuation.resume(returning: self.accumulator.snapshot)
            }
        }
    }

    func pause() async -> RecordingDiagnosticsSnapshot {
        await withCheckedContinuation { continuation in
            queue.async {
                if self.timer != nil {
                    self.timer?.cancel()
                    self.timer = nil
                    self.measure(isBaseline: false)
                    self.accumulator.endSegment()
                }
                self.persistAndPublish()
                continuation.resume(returning: self.accumulator.snapshot)
            }
        }
    }

    private func measure(isBaseline: Bool) {
        let reading: ProcessResourceReading?
        let failure: String?
        do { reading = try ProcessResourceProbe.read(); failure = nil }
        catch { reading = nil; failure = error.localizedDescription }
        let time = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        if isBaseline { accumulator.begin(reading: reading, at: time, error: failure) }
        else { accumulator.sample(reading: reading, at: time, error: failure) }
    }

    private func persistAndPublish() {
        accumulator.setPersistenceError(nil)
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(accumulator.snapshot).write(to: folder.appendingPathComponent("diagnostics.json"), options: .atomic)
        } catch {
            accumulator.setPersistenceError("Resource measurements could not be saved: \(error.localizedDescription)")
        }
        onUpdate(accumulator.snapshot)
    }

    deinit { timer?.cancel() }
}
