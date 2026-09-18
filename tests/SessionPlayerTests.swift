// Run through scripts/test-session-player.sh; real session folders are opt-in.
import Foundation
import AVFoundation

@main
struct SessionPlayerTests {
    @MainActor
    static func main() async throws {
        let synthetic = CommandLine.arguments.contains("--synthetic")
        let folders = CommandLine.arguments.dropFirst().filter { $0 != "--synthetic" }.map { URL(fileURLWithPath: $0) }
        precondition(!folders.isEmpty, "Pass explicit session-folder paths or use scripts/test-session-player.sh")
        var sessions: [RecordingSession] = []
        for folder in folders {
            let manifest = folder.appendingPathComponent("manifest.json")
            guard FileManager.default.fileExists(atPath: manifest.path) else { continue }
            var session = try RecordingSession.decoder().decode(RecordingSession.self, from: Data(contentsOf: manifest))
            guard session.status == "complete" else { continue }
            session.url = folder
            sessions.append(session)
            let built = try await SessionCompositionBuilder.make(session: session)
            let videos = try await built.composition.loadTracks(withMediaType: .video)
            let audios = try await built.composition.loadTracks(withMediaType: .audio)
            precondition(videos.count == 1)
            precondition(audios.count == (session.configuration.recordMicrophone ? 1 : 0) + (session.configuration.recordSystemAudio ? 1 : 0))
            precondition(abs(built.duration - session.durationSeconds) < 0.02, "Unexpected playback duration")
            let clips = videos[0].segments.filter { !$0.isEmpty }
            precondition(clips.count == session.chunks.count, "A recorded clip was lost")
            for (index, segment) in built.segments.enumerated() {
                let midpoint = segment.recordedStart + segment.duration / 2
                precondition(abs(built.originalOffset(for: midpoint) - (segment.originalStart + segment.duration / 2)) < 0.000001)
                if index > 0 {
                    let previous = built.segments[index - 1]
                    precondition(abs(segment.recordedStart - (previous.recordedStart + previous.duration)) < 0.0001)
                }
            }
            for track in audios {
                var end = 0.0
                for part in track.segments where !part.isEmpty {
                    precondition(part.timeMapping.target.start.seconds >= end - 0.0001, "Audio overlap")
                    end = part.timeMapping.target.end.seconds
                    precondition(end <= built.duration + 0.0001, "AAC padding exceeds playback duration")
                }
            }
            let muted = built.audioMix(microphoneMuted: true, systemMuted: false)
            for input in muted.inputParameters {
                var start: Float = -1, end: Float = -1
                var range = CMTimeRange.invalid
                precondition(input.getVolumeRamp(for: .zero, startVolume: &start, endVolume: &end, timeRange: &range))
                precondition(start == (input.trackID == built.microphoneTrackID ? 0 : 1))
            }
            print("PASS composition \(session.id) chunks=\(clips.count) duration=\(built.duration) audioTracks=\(audios.count)")
        }
        precondition(!sessions.isEmpty, "No completed sessions were supplied")
        var missing = sessions.last!
        missing.url = sessions.last!.url.appendingPathComponent("nonexistent-playback-test")
        do { _ = try await SessionCompositionBuilder.make(session: missing); fatalError("Missing files accepted") }
        catch SessionPlaybackError.missingClip { print("PASS missing-file error") }
        var incomplete = sessions.last!
        incomplete.status = "interrupted"
        do { _ = try await SessionCompositionBuilder.make(session: incomplete); fatalError("Incomplete session accepted") }
        catch SessionPlaybackError.unfinished { print("PASS incomplete-session error") }

        let narrationContent = try await SessionCompositionBuilder.make(session: sessions.first!)
        let systemRMS = try await mixedRMS(narrationContent, micMuted: true, systemMuted: false)
        let microphoneRMS = try await mixedRMS(narrationContent, micMuted: false, systemMuted: true)
        let silentRMS = try await mixedRMS(narrationContent, micMuted: true, systemMuted: true)
        precondition(silentRMS < 0.000001, "Both muted tracks must decode to silence")
        if synthetic {
            precondition(systemRMS > 0.01 && microphoneRMS > 0.00001 && systemRMS > microphoneRMS * 10)
            precondition(narrationContent.segments.count == 3)
            precondition(abs(narrationContent.originalOffset(for: 9) - 13) < 0.01, "Manual pause was not removed from playback")
        }
        print("PASS decoded audio mix systemRMS=\(systemRMS) microphoneRMS=\(microphoneRMS) bothMutedRMS=\(silentRMS)")

        let model = SessionPlaybackModel()
        await model.load(sessions.last!)
        for _ in 0..<80 where model.isLoading { try await Task.sleep(nanoseconds: 50_000_000) }
        precondition(model.canPlay, "Player never became ready: \(model.errorMessage ?? "no error")")
        precondition(model.player?.rate == 0, "Recording autoplayed")
        let target = min(61, model.duration * 0.65)
        model.previewPosition(target)
        try await Task.sleep(nanoseconds: 500_000_000)
        precondition(abs((model.player?.currentTime().seconds ?? -1) - target) < 0.1, "Seek failed")
        precondition(model.player?.rate == 0, "Paused seek started playback")
        model.setMicrophoneMuted(true)
        model.setSystemAudioMuted(true)
        precondition(model.microphoneMuted && model.systemAudioMuted)
        model.previewPosition(model.duration)
        try await Task.sleep(nanoseconds: 300_000_000)
        precondition(model.hasEnded && !model.isPlaying)
        model.togglePlayback()
        try await Task.sleep(nanoseconds: 200_000_000)
        precondition(!model.hasEnded && model.isPlaying && model.position < 1, "Replay did not restart")
        model.togglePlayback()
        model.skip(by: -10)
        try await Task.sleep(nanoseconds: 150_000_000)
        precondition(model.position >= 0 && !model.isPlaying)
        await model.load(sessions.first!)
        for _ in 0..<80 where model.isLoading { try await Task.sleep(nanoseconds: 50_000_000) }
        precondition(model.canPlay && model.position < 0.1 && model.player?.rate == 0, "Session change did not reset playback")
        model.release()
        precondition(model.player == nil && !model.isPlaying && model.duration == 0)
        print("PASS player ready, no autoplay, seek, independent mutes, end/replay, skip, session switch, and release")
    }

    static func mixedRMS(_ content: SessionPlaybackContent, micMuted: Bool, systemMuted: Bool) async throws -> Double {
        let tracks = try await content.composition.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: content.composition)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: 0.5, preferredTimescale: 600), duration: CMTime(seconds: min(2, content.duration - 0.5), preferredTimescale: 600))
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.audioMix = content.audioMix(microphoneMuted: micMuted, systemMuted: systemMuted)
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? NSError(domain: "PlaybackAudit", code: 1) }
        var squares = 0.0, count = 0
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { fatalError("No audio data") }
            var data = Data(count: CMBlockBufferGetDataLength(block))
            let size = data.count
            data.withUnsafeMutableBytes { bytes in
                precondition(CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: bytes.baseAddress!) == noErr)
            }
            data.withUnsafeBytes { bytes in
                for value in bytes.bindMemory(to: Int16.self) { let normalized = Double(value) / 32768; squares += normalized * normalized; count += 1 }
            }
        }
        if let error = reader.error { throw error }
        precondition(count > 0)
        return sqrt(squares / Double(count))
    }
}
