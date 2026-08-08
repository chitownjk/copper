import Accelerate
import AVFoundation
import Foundation

public enum AudioMixError: Error, LocalizedError {
    case noUsableInput
    case unsupportedFormat(URL)
    case conversionFailed(URL, Error?)

    public var errorDescription: String? {
        switch self {
        case .noUsableInput:
            return "No audio was recorded — both tracks are missing or empty."
        case .unsupportedFormat(let url):
            return "Unsupported audio format in \(url.lastPathComponent)."
        case .conversionFailed(let url, let underlying):
            let detail = underlying?.localizedDescription ?? "unknown error"
            return "Could not resample \(url.lastPathComponent): \(detail)"
        }
    }
}

/// Offline mixdown of the recorded tracks into the single 16 kHz mono WAV the
/// transcription engines expect.
///
/// This reproduces the semantics of the ffmpeg graph it replaced —
/// `amix=inputs=2:duration=longest:normalize=0` followed by `-ar 16000 -ac 1`:
/// inputs are summed without attenuation, multi-channel inputs are averaged down
/// to mono, the result is as long as the longest input, and a shorter input is
/// treated as silence past its end. Processing is streamed in chunks so a
/// multi-hour recording never lands in memory all at once.
///
/// One deliberate change from the ffmpeg path: `amix` needed a common channel
/// layout, so ffmpeg upmixed the mono mic to stereo through libswresample's
/// energy-preserving matrix and scaled it by 1/√2 — the user's own voice landed
/// 3 dB below everyone else's in the transcription mix. Both tracks are summed
/// at unity here. See `AudioMixerGoldenTests` for the measurement.
public enum AudioMixer {
    public static let sampleRate: Double = 16_000

    /// Output frames processed per iteration (~1 s at 16 kHz).
    private static let chunkFrames = 16_384

    public static func mix(systemURL: URL, micURL: URL, outputURL: URL) async throws {
        try await mix(inputs: [systemURL, micURL], outputURL: outputURL)
    }

    public static func mix(inputs: [URL], outputURL: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try mixSynchronously(inputs: inputs, outputURL: outputURL)
        }.value
    }

    /// Synchronous entry point — used by the tests and by the async wrappers above.
    public static func mixSynchronously(inputs: [URL], outputURL: URL) throws {
        var readers: [MonoDownsampler] = []
        for url in inputs {
            if let reader = try MonoDownsampler(
                url: url,
                targetSampleRate: sampleRate,
                chunkFrames: chunkFrames
            ) {
                readers.append(reader)
            }
        }

        // `duration=longest`: the output runs as long as the longest input.
        guard let totalFrames = readers.map(\.targetFrameCount).max(), totalFrames > 0 else {
            throw AudioMixError.noUsableInput
        }

        try? FileManager.default.removeItem(at: outputURL)
        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        guard let accumulator = AVAudioPCMBuffer(
            pcmFormat: outputFile.processingFormat,
            frameCapacity: AVAudioFrameCount(chunkFrames)
        ), let mixed = accumulator.floatChannelData?[0] else {
            throw AudioMixError.unsupportedFormat(outputURL)
        }

        var low: Float = -1.0
        var high: Float = 1.0
        var position = 0

        while position < totalFrames {
            let frames = min(chunkFrames, totalFrames - position)
            mixed.update(repeating: 0, count: frames)

            for reader in readers {
                let produced = try reader.read(maxFrames: frames)
                guard produced > 0 else { continue }
                vDSP_vadd(mixed, 1, reader.output, 1, mixed, 1, vDSP_Length(produced))
            }

            // `normalize=0` sums without attenuation, so two loud tracks can exceed
            // full scale. ffmpeg saturates on the way to s16; do the same.
            vDSP_vclip(mixed, 1, &low, &high, mixed, 1, vDSP_Length(frames))

            accumulator.frameLength = AVAudioFrameCount(frames)
            try outputFile.write(from: accumulator)
            position += frames
        }
    }
}

/// Streams one audio file as mono Float32 at a target sample rate.
///
/// Channels are averaged to mono at the source rate first, then a single
/// mono→mono `AVAudioConverter` handles resampling — this avoids relying on
/// Core Audio's implicit multi-channel downmix matrix.
private final class MonoDownsampler {
    /// Frames this input contributes to the mix, derived from its own duration.
    let targetFrameCount: Int

    private let url: URL
    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let sourceBuffer: AVAudioPCMBuffer
    private let monoBuffer: AVAudioPCMBuffer
    private let outputBuffer: AVAudioPCMBuffer
    private var produced = 0
    private var sourceExhausted = false

    /// Valid for `read(maxFrames:)`'s return count, until the next call.
    var output: UnsafePointer<Float> {
        UnsafePointer(outputBuffer.floatChannelData![0])
    }

    /// Returns `nil` for an input that simply isn't there (a track the user never
    /// granted permission for, or a recording that stopped before any audio
    /// arrived). Genuine decode failures throw.
    init?(url: URL, targetSampleRate: Double, chunkFrames: Int) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0 else { return nil }

        let sourceFormat = file.processingFormat
        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceFormat.sampleRate,
            channels: 1,
            interleaved: false
        ), let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: monoFormat, to: targetFormat),
            let sourceBuffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: AVAudioFrameCount(chunkFrames)
            ),
            let monoBuffer = AVAudioPCMBuffer(
                pcmFormat: monoFormat,
                frameCapacity: AVAudioFrameCount(chunkFrames)
            ),
            let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: AVAudioFrameCount(chunkFrames)
            )
        else {
            throw AudioMixError.unsupportedFormat(url)
        }

        // Transcription accuracy is worth the extra cycles: mastering-quality SRC
        // keeps us within ~1 dB of ffmpeg's soxr output (see AudioMixerGoldenTests),
        // and mixing runs once per meeting, offline.
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue

        self.url = url
        self.file = file
        self.converter = converter
        self.sourceBuffer = sourceBuffer
        self.monoBuffer = monoBuffer
        self.outputBuffer = outputBuffer
        self.targetFrameCount = Int(
            (Double(file.length) * targetSampleRate / sourceFormat.sampleRate).rounded()
        )
    }

    /// Produces up to `maxFrames` of mono audio at the target rate into `output`.
    /// Returns 0 once this input is spent; the caller pads the rest with silence.
    func read(maxFrames: Int) throws -> Int {
        let remaining = targetFrameCount - produced
        guard remaining > 0 else { return 0 }

        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { [self] _, inputStatus in
            guard !sourceExhausted else {
                inputStatus.pointee = .endOfStream
                return nil
            }
            sourceBuffer.frameLength = sourceBuffer.frameCapacity
            do {
                try file.read(into: sourceBuffer)
            } catch {
                sourceExhausted = true
                inputStatus.pointee = .endOfStream
                return nil
            }
            guard sourceBuffer.frameLength > 0 else {
                sourceExhausted = true
                inputStatus.pointee = .endOfStream
                return nil
            }
            downmixToMono()
            inputStatus.pointee = .haveData
            return monoBuffer
        }

        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            break
        case .error:
            throw AudioMixError.conversionFailed(url, conversionError)
        @unknown default:
            throw AudioMixError.conversionFailed(url, conversionError)
        }

        let count = min(Int(outputBuffer.frameLength), remaining, maxFrames)
        produced += count
        return count
    }

    private func downmixToMono() {
        let frames = Int(sourceBuffer.frameLength)
        let channels = Int(sourceBuffer.format.channelCount)
        let source = sourceBuffer.floatChannelData!
        let destination = monoBuffer.floatChannelData![0]
        monoBuffer.frameLength = sourceBuffer.frameLength

        if channels == 1 {
            destination.update(from: source[0], count: frames)
            return
        }

        destination.update(from: source[0], count: frames)
        for channel in 1..<channels {
            vDSP_vadd(destination, 1, source[channel], 1, destination, 1, vDSP_Length(frames))
        }
        var divisor = Float(channels)
        vDSP_vsdiv(destination, 1, &divisor, destination, 1, vDSP_Length(frames))
    }
}
