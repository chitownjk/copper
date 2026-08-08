import AVFoundation
import XCTest
@testable import MeetingCore

/// Covers the semantics the ffmpeg graph used to provide:
/// `amix=inputs=2:duration=longest:normalize=0` → `-ar 16000 -ac 1`.
///
/// Output lengths here were cross-checked against real ffmpeg output; see
/// `testLongestInputDeterminesOutputLength` for the reference numbers.
final class AudioMixerTests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioMixerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: - Format

    func testOutputIs16kHzMonoInt16() throws {
        let system = try writeFixture("system.wav", seconds: 1.0, sampleRate: 48_000, channels: 2) { _, _ in 0.2 }
        let mic = try writeFixture("mic.wav", seconds: 1.0, sampleRate: 48_000, channels: 1) { _, _ in 0.1 }
        let output = workDir.appendingPathComponent("mixed.wav")

        try AudioMixer.mixSynchronously(inputs: [system, mic], outputURL: output)

        let file = try AVAudioFile(forReading: output)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(file.fileFormat.commonFormat, .pcmFormatInt16)
    }

    // MARK: - duration=longest

    func testLongestInputDeterminesOutputLength() throws {
        // The real spike recording: system 30.54 s + mic 30.70 s at 48 kHz.
        // ffmpeg produced 491200 frames (30.70 s × 16000); so must we.
        let system = try writeFixture("system.wav", seconds: 30.54, sampleRate: 48_000, channels: 2) { _, _ in 0 }
        let mic = try writeFixture("mic.wav", seconds: 30.70, sampleRate: 48_000, channels: 1) { _, _ in 0 }
        let output = workDir.appendingPathComponent("mixed.wav")

        try AudioMixer.mixSynchronously(inputs: [system, mic], outputURL: output)

        XCTAssertEqual(try AVAudioFile(forReading: output).length, 491_200)
    }

    func testShorterInputIsPaddedWithSilence() throws {
        let long = try writeFixture("long.wav", seconds: 2.0, sampleRate: 48_000, channels: 1) { _, _ in 0.5 }
        let short = try writeFixture("short.wav", seconds: 0.5, sampleRate: 48_000, channels: 1) { _, _ in 0.5 }
        let output = workDir.appendingPathComponent("mixed.wav")

        try AudioMixer.mixSynchronously(inputs: [long, short], outputURL: output)

        let samples = try readSamples(output)
        XCTAssertEqual(samples.count, 32_000)
        // Overlap region: both tracks contribute.
        XCTAssertEqual(samples[4_000], 1.0, accuracy: 0.02)
        // Past the short track's end: only the long one is left.
        XCTAssertEqual(samples[24_000], 0.5, accuracy: 0.02)
    }

    // MARK: - normalize=0

    func testInputsAreSummedNotAveraged() throws {
        let a = try writeFixture("a.wav", seconds: 1.0, sampleRate: 48_000, channels: 1) { _, _ in 0.3 }
        let b = try writeFixture("b.wav", seconds: 1.0, sampleRate: 48_000, channels: 1) { _, _ in 0.3 }
        let output = workDir.appendingPathComponent("mixed.wav")

        try AudioMixer.mixSynchronously(inputs: [a, b], outputURL: output)

        // normalize=1 would give 0.3; normalize=0 gives 0.6.
        XCTAssertEqual(try readSamples(output)[8_000], 0.6, accuracy: 0.02)
    }

    func testSumBeyondFullScaleSaturates() throws {
        let a = try writeFixture("a.wav", seconds: 1.0, sampleRate: 48_000, channels: 1) { _, _ in 0.9 }
        let b = try writeFixture("b.wav", seconds: 1.0, sampleRate: 48_000, channels: 1) { _, _ in 0.9 }
        let output = workDir.appendingPathComponent("mixed.wav")

        try AudioMixer.mixSynchronously(inputs: [a, b], outputURL: output)

        // 1.8 must clip to full scale, never wrap to a negative Int16.
        XCTAssertEqual(try readSamples(output)[8_000], 1.0, accuracy: 0.001)
    }

    // MARK: - Silence and channel handling

    func testSilenceInSilenceOut() throws {
        let a = try writeFixture("a.wav", seconds: 1.0, sampleRate: 48_000, channels: 2) { _, _ in 0 }
        let b = try writeFixture("b.wav", seconds: 1.0, sampleRate: 48_000, channels: 1) { _, _ in 0 }
        let output = workDir.appendingPathComponent("mixed.wav")

        try AudioMixer.mixSynchronously(inputs: [a, b], outputURL: output)

        let samples = try readSamples(output)
        XCTAssertEqual(samples.count, 16_000)
        XCTAssertEqual(samples.map(abs).max() ?? 0, 0, accuracy: 0.0001)
    }

    func testStereoIsAveragedToMono() throws {
        // Left at 0.8, right at 0.2 → mono 0.5, matching ffmpeg's `-ac 1` downmix.
        let stereo = try writeFixture("stereo.wav", seconds: 1.0, sampleRate: 48_000, channels: 2) { channel, _ in
            channel == 0 ? 0.8 : 0.2
        }
        let output = workDir.appendingPathComponent("mixed.wav")

        try AudioMixer.mixSynchronously(inputs: [stereo], outputURL: output)

        XCTAssertEqual(try readSamples(output)[8_000], 0.5, accuracy: 0.02)
    }

    func testResamplesFromNonStandardRate() throws {
        let a = try writeFixture("a.wav", seconds: 1.0, sampleRate: 44_100, channels: 1) { _, _ in 0.4 }
        let output = workDir.appendingPathComponent("mixed.wav")

        try AudioMixer.mixSynchronously(inputs: [a], outputURL: output)

        let samples = try readSamples(output)
        XCTAssertEqual(samples.count, 16_000)
        XCTAssertEqual(samples[8_000], 0.4, accuracy: 0.02)
    }

    // MARK: - Degenerate inputs

    func testMissingTrackIsTreatedAsSilence() throws {
        // Screen Recording denied → no system.wav on disk. ffmpeg failed outright here.
        let mic = try writeFixture("mic.wav", seconds: 1.0, sampleRate: 48_000, channels: 1) { _, _ in 0.5 }
        let missing = workDir.appendingPathComponent("system.wav")
        let output = workDir.appendingPathComponent("mixed.wav")

        try AudioMixer.mixSynchronously(inputs: [missing, mic], outputURL: output)

        let samples = try readSamples(output)
        XCTAssertEqual(samples.count, 16_000)
        XCTAssertEqual(samples[8_000], 0.5, accuracy: 0.02)
    }

    func testNoUsableInputThrows() throws {
        let output = workDir.appendingPathComponent("mixed.wav")
        XCTAssertThrowsError(
            try AudioMixer.mixSynchronously(
                inputs: [workDir.appendingPathComponent("nope.wav")],
                outputURL: output
            )
        ) { error in
            guard case AudioMixError.noUsableInput = error else {
                return XCTFail("expected .noUsableInput, got \(error)")
            }
        }
    }

    func testOverwritesExistingOutput() throws {
        let a = try writeFixture("a.wav", seconds: 2.0, sampleRate: 48_000, channels: 1) { _, _ in 0.1 }
        let output = workDir.appendingPathComponent("mixed.wav")
        try Data(repeating: 0xFF, count: 4_096).write(to: output)

        try AudioMixer.mixSynchronously(inputs: [a], outputURL: output)

        XCTAssertEqual(try AVAudioFile(forReading: output).length, 32_000)
    }

    // MARK: - Helpers

    /// Writes a Float32 WAV like the ones `MicRecorder` / `SystemAudioRecorder` produce.
    private func writeFixture(
        _ name: String,
        seconds: Double,
        sampleRate: Double,
        channels: AVAudioChannelCount,
        sample: (Int, Int) -> Float
    ) throws -> URL {
        let url = workDir.appendingPathComponent(name)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        )!
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let frames = Int((seconds * sampleRate).rounded())
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<Int(channels) {
            let data = buffer.floatChannelData![channel]
            for frame in 0..<frames {
                data[frame] = sample(channel, frame)
            }
        }
        try file.write(from: buffer)
        return url
    }

    private func readSamples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        )!
        try file.read(into: buffer)
        let data = buffer.floatChannelData![0]
        return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
    }
}
