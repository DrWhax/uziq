import AVFoundation
import Foundation

/// Builds a compact, static waveform from a local audio file. Playback itself
/// remains on AVAudioPlayer; this only reads a small number of samples for the
/// visual timeline and never touches the microphone.
enum WaveformSampler {
    static func samples(for url: URL, count: Int = 140) -> [CGFloat] {
        guard count > 0, let file = try? AVAudioFile(forReading: url), file.length > 0 else { return [] }
        let format = file.processingFormat
        let totalFrames = Int64(file.length)
        var values = [CGFloat](repeating: 0, count: count)

        for bucket in 0..<count {
            let start = (totalFrames * Int64(bucket)) / Int64(count)
            let end = max(start + 1, (totalFrames * Int64(bucket + 1)) / Int64(count))
            let frameCount = AVAudioFrameCount(min(end - start, Int64(UInt32.max)))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { continue }

            do {
                file.framePosition = AVAudioFramePosition(start)
                try file.read(into: buffer, frameCount: frameCount)
            } catch {
                continue
            }

            guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { continue }
            let frameTotal = Int(buffer.frameLength)
            let stride = max(1, frameTotal / 512)
            var sum: Float = 0
            var sampled = 0
            var index = 0
            while index < frameTotal {
                let value = channel[index]
                sum += value * value
                sampled += 1
                index += stride
            }
            values[bucket] = CGFloat(sqrt(sum / Float(max(sampled, 1))))
        }

        let peak = values.max() ?? 0
        guard peak > 0 else { return values.map { _ in 0.12 } }
        return values.map { max(0.08, min(1, $0 / peak)) }
    }
}
