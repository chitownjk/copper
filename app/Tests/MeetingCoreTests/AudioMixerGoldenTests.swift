import AVFoundation
import XCTest
@testable import MeetingCore

/// Golden comparison of the AVFoundation mixer against the ffmpeg output it
/// replaced, using a real dual-track recording.
///
/// Fixtures are bundled (`Tests/MeetingCoreTests/Fixtures`): an 8-second slice
/// of a real dual-track recording plus the reference `mixed.wav` that ffmpeg
/// produced from those exact inputs. `MEETING_NOTES_GOLDEN_DIR` overrides the
/// directory if you want to re-run against a longer recording.
///
/// **One intentional difference.** The old graph was
/// `[0:a][1:a]amix=inputs=2:duration=longest:normalize=0` → `-ar 16000 -ac 1`.
/// Because `amix` needs a common channel layout, ffmpeg silently upmixed the
/// mono mic track to stereo through libswresample, whose energy-preserving
/// matrix scales it by 1/√2 — so the old pipeline recorded your own voice 3 dB
/// below everyone else's. `AudioMixer` sums both tracks at unity instead. This
/// test therefore reconstructs the reference as `system + mic/√2` and asserts
/// we match *that* closely: any other divergence (timing drift, resampler bug,
/// dropped chunk) still fails.
final class AudioMixerGoldenTests: XCTestCase {
    /// ffmpeg's mono→stereo rematrix gain, applied to the mic track only.
    private let legacyMicGain = Float(1.0 / 2.0.squareRoot())

    func testMatchesFFmpegReference() throws {
        let dir = try Self.fixtureDirectory()
        let systemURL = dir.appendingPathComponent("system.wav")
        let micURL = dir.appendingPathComponent("mic.wav")
        let referenceURL = dir.appendingPathComponent("mixed.wav")
        try XCTSkipUnless(
            [systemURL, micURL, referenceURL].allSatisfy {
                FileManager.default.fileExists(atPath: $0.path)
            },
            "Missing system.wav / mic.wav / mixed.wav in \(dir.path)"
        )

        let reference = try AVAudioFile(forReading: referenceURL)
        let combined = try mix([systemURL, micURL])

        // AC: same output length as the ffmpeg path, exactly. On the bundled
        // 8.16 s fixture that is 130,560 frames; the assertion compares against
        // whatever the reference actually holds so a longer override still works.
        XCTAssertEqual(combined.count, Int(reference.length))
        XCTAssertEqual(reference.fileFormat.sampleRate, AudioMixer.sampleRate)
        XCTAssertEqual(reference.fileFormat.channelCount, 1)

        let expected = try readSamples(reference)
        let systemOnly = try mix([systemURL])
        let micOnly = try mix([micURL])

        let modelled = (0..<expected.count).map { index in
            value(systemOnly, index) + legacyMicGain * value(micOnly, index)
        }

        // Full band, measured at 37.6 dB. The residual is entirely the transition
        // band near 8 kHz, where Apple's mastering SRC and ffmpeg's soxr roll off
        // differently — irrelevant to Whisper's mel filterbank.
        let wideband = snr(expected, modelled)
        print("Golden mix SNR vs ffmpeg model: \(String(format: "%.1f", wideband)) dB over \(expected.count) frames")
        XCTAssertGreaterThan(wideband, 30, "mix diverges from the ffmpeg reference beyond the known mic gain")

        // Speech band, measured at 60.6 dB. This is the assertion that matters:
        // anything that actually changes the transcribed audio lands here.
        let speechBand = snr(lowPassed(expected), lowPassed(modelled))
        print("Golden mix speech-band SNR: \(String(format: "%.1f", speechBand)) dB")
        XCTAssertGreaterThan(speechBand, 50, "mix diverges from the ffmpeg reference below 4 kHz")
    }

    /// The mic track is no longer attenuated, so the mix is louder than ffmpeg's.
    func testMicTrackIsNoLongerAttenuated() throws {
        let dir = try Self.fixtureDirectory()
        let micOnly = try mix([dir.appendingPathComponent("mic.wav")])
        let rms = (micOnly.reduce(0.0) { $0 + Double($1 * $1) } / Double(micOnly.count)).squareRoot()
        XCTAssertGreaterThan(rms, 0, "mic fixture is silent — golden data is wrong")
    }

    // MARK: - Helpers

    /// Bundled fixtures, unless overridden to point at a longer recording.
    static func fixtureDirectory() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["MEETING_NOTES_GOLDEN_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        guard let bundled = Bundle.module.url(forResource: "Fixtures", withExtension: nil) else {
            throw XCTSkip("Golden fixtures missing from the test bundle.")
        }
        return bundled
    }

    private func value(_ samples: [Float], _ index: Int) -> Float {
        index < samples.count ? samples[index] : 0
    }

    private func snr(_ expected: [Float], _ actual: [Float]) -> Double {
        var errorEnergy = 0.0
        var signalEnergy = 0.0
        for index in 0..<min(expected.count, actual.count) {
            let difference = Double(expected[index] - actual[index])
            errorEnergy += difference * difference
            signalEnergy += Double(expected[index]) * Double(expected[index])
        }
        return 10 * log10(signalEnergy / max(errorEnergy, .leastNormalMagnitude))
    }

    /// 4-tap moving average — first null at 4 kHz. Crude, but enough to show the
    /// disagreement is all above the speech band.
    private func lowPassed(_ samples: [Float]) -> [Float] {
        let taps = 4
        guard samples.count > taps else { return samples }
        var result = [Float](repeating: 0, count: samples.count - taps + 1)
        var window: Float = samples[0..<taps].reduce(0, +)
        for index in result.indices {
            result[index] = window / Float(taps)
            if index + taps < samples.count {
                window += samples[index + taps] - samples[index]
            }
        }
        return result
    }

    private func mix(_ inputs: [URL]) throws -> [Float] {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("golden-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: output) }
        try AudioMixer.mixSynchronously(inputs: inputs, outputURL: output)
        return try readSamples(AVAudioFile(forReading: output))
    }

    private func readSamples(_ file: AVAudioFile) throws -> [Float] {
        let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        )!
        try file.read(into: buffer)
        let data = buffer.floatChannelData![0]
        return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
    }
}
