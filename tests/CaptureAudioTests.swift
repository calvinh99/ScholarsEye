import AVFoundation
import Foundation

private enum TestFailure: Error { case failed(String) }

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure.failed(message) }
}

private func sourceSample(interleaved: Bool, channels: AVAudioChannelCount, count: Int, time: CMTime) throws -> CMSampleBuffer {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                              channels: channels, interleaved: interleaved)!
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
    pcm.frameLength = AVAudioFrameCount(count)
    let buffers = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
    for channel in 0..<Int(channels) {
        let buffer = buffers[interleaved ? 0 : channel]
        let samples = buffer.mData!.assumingMemoryBound(to: Float.self)
        for frame in 0..<count {
            samples[interleaved ? frame * Int(channels) + channel : frame] = Float(channel * 10_000 + frame)
        }
    }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
                                  presentationTimeStamp: time, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    try expect(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
        makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription,
        sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
        sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr, "Create native PCM sample")
    try expect(CMSampleBufferSetDataBufferFromAudioBufferList(sample!, blockBufferAllocator: kCFAllocatorDefault,
        blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList) == noErr, "Attach channel data")
    try expect(CMSampleBufferSetDataReady(sample!) == noErr, "Mark sample ready")
    return sample!
}

private func checkData(_ sample: CMSampleBuffer, originalRange: Range<Int>, originalTime: CMTime) throws {
    let format = AVAudioFormat(cmAudioFormatDescription: CMSampleBufferGetFormatDescription(sample)!)
    try expect(CMSampleBufferGetNumSamples(sample) == originalRange.count, "Copied frame count")
    try expect(CMSampleBufferGetPresentationTimeStamp(sample)
        == originalTime + CMTime(value: Int64(originalRange.lowerBound), timescale: 48_000), "Copied timestamp")
    try expect(CMSampleBufferDataIsReady(sample), "Copied sample is ready")
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(originalRange.count))!
    pcm.frameLength = AVAudioFrameCount(originalRange.count)
    try expect(CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0,
        frameCount: Int32(originalRange.count), into: pcm.mutableAudioBufferList) == noErr, "Read copied PCM")
    let buffers = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
    for channel in 0..<Int(format.channelCount) {
        let samples = buffers[format.isInterleaved ? 0 : channel].mData!.assumingMemoryBound(to: Float.self)
        for frame in 0..<originalRange.count {
            let actual = samples[format.isInterleaved ? frame * Int(format.channelCount) + channel : frame]
            let expected = Float(channel * 10_000 + originalRange.lowerBound + frame)
            try expect(actual == expected, "Preserve exact channel \(channel), frame \(frame) value")
        }
    }
}

@main
struct CaptureAudioTests {
    static func main() throws {
        let boundary = CMTime(value: 60, timescale: 1)
        // Mirrors the actual 925/35 split which exposed planar stereo loss.
        let time = boundary - CMTime(value: 925, timescale: 48_000)
        for (interleaved, channels) in [(true, 1), (true, 2), (false, 2)] {
            let source = try sourceSample(interleaved: interleaved, channels: AVAudioChannelCount(channels), count: 960, time: time)
            try expect(AudioSampleRange.alignmentPrefix(source, before: boundary) == 925, "Known startup prefix is alignment trim")
            try expect(AudioSampleRange.alignmentPrefix(source, before: .zero) == 0, "Late prior-chunk data inside the segment stays a drop")
            try expect(AudioSampleRange.alignmentPrefix(source, before: time) == 0, "Samples at segment start are inside capture")
            try expect(AudioSampleRange.alignmentPrefix(source, before: nil) == 0, "Unknown segment start never hides loss")
            try expect(AudioSampleRange.alignmentPrefix(source, before: .invalid) == 0, "Invalid segment start never hides loss")
            try expect(AudioSampleRange.alignmentPrefix(source, before: CMTime(value: 61, timescale: 1)) == 960, "Entire packet before resumed capture is alignment trim")
            for (split, expectedLeft) in [(boundary, 925), (boundary + CMTime(value: 1, timescale: 96_000), 926)] {
                let left = AudioSampleRange.intersection(sampleCount: 960, sampleRate: 48_000,
                    sampleTime: time, start: .zero, end: split)
                let right = AudioSampleRange.intersection(sampleCount: 960, sampleRate: 48_000,
                    sampleTime: time, start: split, end: CMTime(value: 120, timescale: 1))
                try expect(left == 0..<expectedLeft && right == expectedLeft..<960, "Partition without gaps or duplicates")
                guard let a = AudioSampleRange.copyPCM(source, range: left),
                      let b = AudioSampleRange.copyPCM(source, range: right) else {
                    throw TestFailure.failed("Copy \(channels)-channel \(interleaved ? "interleaved" : "planar") boundary audio")
                }
                try checkData(a, originalRange: left, originalTime: time)
                try checkData(b, originalRange: right, originalTime: time)
                try expect(CMSampleBufferGetNumSamples(a) + CMSampleBufferGetNumSamples(b) == 960, "Preserve all source frames")
            }
            try expect(AudioSampleRange.copyPCM(source, range: 0..<0) == nil, "Reject empty range")
            try expect(AudioSampleRange.copyPCM(source, range: 900..<961) == nil, "Reject range outside source")
            print("PASS: \(channels)-channel \(interleaved ? "interleaved" : "planar") PCM; sample-aligned and fractional splits; exact values, counts, timestamps")
        }
        let legacy = RecordingChunk(id: 1, fileName: "fixture.mp4", codec: .hevc, startOffsetSeconds: 0, durationSeconds: 60)
        let data = try JSONEncoder().encode(legacy)
        try expect(!(String(data: data, encoding: .utf8) ?? "").contains("alignmentTrimmedAudioSamples"), "Legacy fixture omits the new field")
        let decoded = try JSONDecoder().decode(RecordingChunk.self, from: data)
        try expect(decoded.alignmentTrimmedAudioSamples == nil, "Old manifests remain decodable")
        print("PASS: initial/resume alignment versus late/unknown loss classification; legacy chunk compatibility")
    }
}
