import Foundation

/// Cuts a 16 kHz mono PCM16 stream into sentence-sized WAV files using
/// energy-based silence detection.
///
/// Synchronous by design: the consumer task must never block on the
/// network, or the capture stream (bounded at ~1s of slack) would drop
/// audio while a transcription is in flight. Completed chunks are plain
/// WAV files in the temporary directory; the caller deletes them after use.
///
/// Boundaries: speech starts when a buffer's RMS clears `speechThreshold`;
/// a chunk ends after `silenceDuration` of continuous quiet, provided at
/// least `minSpeechDuration` of speech was seen. Chunks are capped at
/// `maxChunkDuration` so a long monologue still flows instead of growing
/// one file without bound. Trailing silence is trimmed off each chunk.
@MainActor
final class SentenceAudioChunker {
    static let sampleRate = 16_000

    var speechThreshold: Float = 0.02
    var silenceDuration: TimeInterval = 0.9
    var minSpeechDuration: TimeInterval = 0.3
    var maxChunkDuration: TimeInterval = 15

    private var samples: [Int16] = []
    private var trailingSilenceSamples = 0
    private var speechSamples = 0

    private var silenceSampleCount: Int {
        Int(silenceDuration * Double(Self.sampleRate))
    }

    private var minSpeechSampleCount: Int {
        Int(minSpeechDuration * Double(Self.sampleRate))
    }

    private var maxChunkSampleCount: Int {
        Int(maxChunkDuration * Double(Self.sampleRate))
    }

    /// Feeds one PCM16 buffer (16 kHz mono, little-endian). Returns a WAV
    /// file URL when a sentence boundary is reached, else nil.
    func feed(_ data: Data) -> URL? {
        let count = data.count / 2
        guard count > 0 else { return nil }
        let isSpeech = Self.rms(of: data) >= speechThreshold
        if samples.isEmpty, !isSpeech {
            return nil
        }
        samples.append(contentsOf: data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) })
        if isSpeech {
            speechSamples += count
            trailingSilenceSamples = 0
        } else {
            trailingSilenceSamples += count
        }
        if samples.count >= maxChunkSampleCount {
            return emit()
        }
        if trailingSilenceSamples >= silenceSampleCount, speechSamples >= minSpeechSampleCount {
            return emit()
        }
        return nil
    }

    /// Emits whatever speech is buffered (e.g. at session stop). Returns
    /// nil when nothing worth transcribing was said.
    func flush() -> URL? {
        guard speechSamples >= minSpeechSampleCount else {
            reset()
            return nil
        }
        return emit()
    }

    private func emit() -> URL? {
        var body = samples
        if trailingSilenceSamples > 0, trailingSilenceSamples < body.count {
            body.removeLast(trailingSilenceSamples)
        }
        reset()
        guard !body.isEmpty else { return nil }
        return Self.writeWAV(samples: body)
    }

    private func reset() {
        samples = []
        trailingSilenceSamples = 0
        speechSamples = 0
    }

    private static func rms(of data: Data) -> Float {
        let count = data.count / 2
        guard count > 0 else { return 0 }
        var sum: Float = 0
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: Int16.self).baseAddress else { return }
            for index in 0..<count {
                let sample = Float(base[index]) / Float(Int16.max)
                sum += sample * sample
            }
        }
        return (sum / Float(count)).squareRoot()
    }

    private static func writeWAV(samples: [Int16]) -> URL? {
        let dataBytes = samples.count * 2
        var wav = Data()
        wav.append(Data("RIFF".utf8))
        wav.appendUInt32LE(UInt32(36 + dataBytes))
        wav.append(Data("WAVE".utf8))
        wav.append(Data("fmt ".utf8))
        wav.appendUInt32LE(16)
        wav.appendUInt16LE(1)
        wav.appendUInt16LE(1)
        wav.appendUInt32LE(UInt32(sampleRate))
        wav.appendUInt32LE(UInt32(sampleRate * 2))
        wav.appendUInt16LE(2)
        wav.appendUInt16LE(16)
        wav.append(Data("data".utf8))
        wav.appendUInt32LE(UInt32(dataBytes))
        samples.withUnsafeBytes { wav.append(contentsOf: $0) }
        let url = FileManager.default.temporaryDirectory
            .appending(path: "translation-chunk-\(UUID().uuidString).wav")
        do {
            try wav.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
