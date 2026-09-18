import Foundation

enum VideoCodec: String, Codable, CaseIterable, Identifiable {
    case hevc, h264
    var id: String { rawValue }
    var label: String { self == .hevc ? "HEVC · smaller files" : "H.264 · compatibility" }
}

struct CaptureConfiguration: Codable, Equatable {
    var framesPerSecond: Int = 1
    var maxWidth: Int = 2560
    var videoBitrate: Int = 400_000
    var codec: VideoCodec = .hevc
    var recordMicrophone: Bool = true
    var recordSystemAudio: Bool = false
    var chunkDuration: Double = 60

    var estimatedMegabytesPerHour: Double {
        Double(videoBitrate + (recordMicrophone ? 48_000 : 0) + (recordSystemAudio ? 96_000 : 0)) * 3600 / 8 / 1_000_000
    }
}

struct CaptureDisplay: Identifiable, Equatable {
    let id: UInt32
    let name: String
    let width: Int
    let height: Int
}

enum CaptureState: String {
    case idle, recording, paused, stopping
}

struct CaptureStats {
    var durationSeconds: Double = 0
    var bytesWritten: Int64 = 0
    var frameCount: Int = 0
    var chunkCount: Int = 0
    var droppedVideoFrames: Int = 0
    var droppedAudioSamples: Int = 0
    var sessionURL: URL?
}

struct RecordingChunk: Codable, Identifiable {
    let id: Int
    let fileName: String
    let codec: VideoCodec
    var hardwareAccelerated: Bool = true
    let startOffsetSeconds: Double
    var durationSeconds: Double
    var byteCount: Int64 = 0
    var videoFrames: Int = 0
    var droppedVideoFrames: Int = 0
    var droppedAudioSamples: Int = 0
    // Optional so recordings written before this diagnostic remain decodable.
    // These samples precede the capture segment, rather than leaving a gap in it.
    var alignmentTrimmedAudioSamples: Int?
    var microphoneSamples: Int = 0
    var systemAudioSamples: Int = 0
}

struct RecordingEvent: Codable {
    let kind: String
    let atOffsetSeconds: Double
}

struct RecordingSession: Codable, Identifiable {
    var schemaVersion: Int = 1
    let id: String
    let startedAt: Date
    var endedAt: Date?
    var status: String = "recording"
    let configuration: CaptureConfiguration
    let displayID: UInt32
    let displayWidth: Int
    let displayHeight: Int
    var durationSeconds: Double = 0
    var bytesWritten: Int64 = 0
    var chunks: [RecordingChunk] = []
    var events: [RecordingEvent] = []
    var unfinishedFiles: [String] = []
    var failureReason: String?
    var url: URL = URL(fileURLWithPath: "/")

    enum CodingKeys: String, CodingKey {
        case schemaVersion, id, startedAt, endedAt, status, configuration, displayID
        case displayWidth, displayHeight, durationSeconds, bytesWritten, chunks, events
        case unfinishedFiles, failureReason
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func save() throws {
        try Self.encoder().encode(self).write(to: url.appendingPathComponent("manifest.json"), options: .atomic)
    }
}
