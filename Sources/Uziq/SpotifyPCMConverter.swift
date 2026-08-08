import AVFoundation
import Foundation

enum SpotifyPCMConverter {
    static let channelCount = 2
    static let bytesPerSample = MemoryLayout<Float>.size
    static let bytesPerFrame = channelCount * bytesPerSample
    static let outputFormat = AVAudioFormat(
        standardFormatWithSampleRate: 44_100,
        channels: AVAudioChannelCount(channelCount)
    )!

    static func makeBuffer(
        from interleavedData: Data,
        maximumFrameCount: Int? = nil
    ) -> (buffer: AVAudioPCMBuffer, consumedBytes: Int)? {
        let availableFrameCount = interleavedData.count / bytesPerFrame
        let frameCount = min(availableFrameCount, maximumFrameCount ?? availableFrameCount)
        guard frameCount > 0,
              frameCount <= Int(UInt32.max),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: AVAudioFrameCount(frameCount)
              ),
              let channels = buffer.floatChannelData else { return nil }

        let consumedBytes = frameCount * bytesPerFrame
        var samples = [Float](repeating: 0, count: frameCount * channelCount)
        _ = samples.withUnsafeMutableBytes { destination in
            interleavedData.copyBytes(
                to: destination.bindMemory(to: UInt8.self),
                count: consumedBytes
            )
        }

        for frame in 0..<frameCount {
            channels[0][frame] = samples[frame * channelCount]
            channels[1][frame] = samples[frame * channelCount + 1]
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        return (buffer, consumedBytes)
    }
}
