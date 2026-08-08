import AVFoundation
import XCTest
@testable import MeetingCore

/// The filesystem half of crash recovery (E1.5): given a directory left behind
/// by a killed process, is there anything worth recovering and when did it stop?
final class RecordingArtifactsTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifacts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func writeWAV(_ name: String, seconds: Double) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false
        )!
        let file = try AVAudioFile(
            forWriting: url, settings: format.settings,
            commonFormat: .pcmFormatFloat32, interleaved: false
        )
        let frames = AVAudioFrameCount(seconds * 48_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        try file.write(from: buffer)
        return url
    }

    func testEmptyDirectoryHasNothingToRecover() {
        XCTAssertEqual(RecordingArtifacts.audioBytes(in: dir), 0)
        XCTAssertFalse(RecordingArtifacts.isRecoverable(directory: dir))
    }

    func testMissingDirectoryIsHandledRatherThanCrashing() {
        let missing = dir.appendingPathComponent("does-not-exist", isDirectory: true)
        XCTAssertEqual(RecordingArtifacts.audioBytes(in: missing), 0)
        XCTAssertNil(RecordingArtifacts.lastModified(in: missing))
    }

    /// The realistic crash shape: the mic track kept writing after system audio
    /// stopped, and neither file was finalized.
    func testPartialDualTrackRecordingIsRecoverable() throws {
        _ = try writeWAV("system.wav", seconds: 1.0)
        _ = try writeWAV("mic.wav", seconds: 1.5)

        let bytes = RecordingArtifacts.audioBytes(in: dir)
        XCTAssertGreaterThan(bytes, 400_000)
        XCTAssertTrue(RecordingArtifacts.isRecoverable(directory: dir))
    }

    func testOnlyAudioFilesAreCounted() throws {
        _ = try writeWAV("mic.wav", seconds: 0.5)
        try Data(repeating: 0, count: 5_000_000).write(to: dir.appendingPathComponent("transcript.json"))

        // 0.5 s of 48 kHz mono float is ~96 KB; the 5 MB JSON must not inflate it.
        XCTAssertLessThan(RecordingArtifacts.audioBytes(in: dir), 200_000)
    }

    /// Recovery stamps `ended_at` from the last write, not "now" — a crash may
    /// predate the relaunch by hours.
    func testLastModifiedReflectsTheNewestWrite() throws {
        let old = try writeWAV("system.wav", seconds: 0.2)
        let anHourAgo = Date().addingTimeInterval(-3600)
        try FileManager.default.setAttributes([.modificationDate: anHourAgo], ofItemAtPath: old.path)
        _ = try writeWAV("mic.wav", seconds: 0.2)

        let last = try XCTUnwrap(RecordingArtifacts.lastModified(in: dir))
        XCTAssertGreaterThan(last, anHourAgo.addingTimeInterval(60))
    }

    /// A recovered partial recording has to survive the mixer, since that is
    /// the first thing the pipeline does to it.
    func testAPartialRecordingStillMixes() throws {
        _ = try writeWAV("system.wav", seconds: 1.0)
        _ = try writeWAV("mic.wav", seconds: 1.5)
        let output = dir.appendingPathComponent("mixed.wav")

        try AudioMixer.mixSynchronously(
            inputs: [dir.appendingPathComponent("system.wav"), dir.appendingPathComponent("mic.wav")],
            outputURL: output
        )
        XCTAssertEqual(try AVAudioFile(forReading: output).length, 24_000) // 1.5 s at 16 kHz
    }

    /// The worst crash shape: system audio was never granted, so only the mic
    /// track exists. Still recoverable.
    func testSingleTrackRecordingStillMixes() throws {
        _ = try writeWAV("mic.wav", seconds: 2.0)
        let output = dir.appendingPathComponent("mixed.wav")

        try AudioMixer.mixSynchronously(inputs: [
            dir.appendingPathComponent("system.wav"), // never created
            dir.appendingPathComponent("mic.wav")
        ], outputURL: output)
        XCTAssertEqual(try AVAudioFile(forReading: output).length, 32_000)
    }
}

final class DiskSpaceTests: XCTestCase {
    func testThresholdsAreOrderedAndMatchTheStory() {
        // E1.5: refuse to start under 2 GB, warn mid-recording under 1 GB.
        XCTAssertEqual(DiskSpace.requiredToStartBytes, 2 * 1_024 * 1_024 * 1_024)
        XCTAssertEqual(DiskSpace.warnDuringRecordingBytes, 1_024 * 1_024 * 1_024)
        XCTAssertGreaterThan(DiskSpace.requiredToStartBytes, DiskSpace.warnDuringRecordingBytes)
    }

    func testReadsRealFreeSpaceForTheApplicationSupportVolume() throws {
        let available = try XCTUnwrap(
            DiskSpace.availableBytes(),
            "could not read free space on the volume holding Application Support"
        )
        XCTAssertGreaterThan(available, 0)
    }

    /// An unqueryable volume must not block recording — failing open is the
    /// right call when the only alternative is refusing to record.
    func testUnknownVolumeFailsOpen() {
        let bogus = URL(fileURLWithPath: "/nonexistent-volume-\(UUID().uuidString)")
        XCTAssertNil(DiskSpace.availableBytes(at: bogus))
        XCTAssertTrue(DiskSpace.canStartRecording(at: bogus))
        XCTAssertFalse(DiskSpace.isLowDuringRecording(at: bogus))
    }

    func testErrorMessageNamesBothTheShortfallAndTheRequirement() {
        let message = DiskSpaceError.insufficientToStart(available: 512 * 1_024 * 1_024)
            .localizedDescription
        // ByteCountFormatter renders in decimal units, so 512 MiB reads "536.9 MB".
        XCTAssertTrue(message.contains("536.9 MB"), message)
        XCTAssertTrue(message.contains("2.15 GB"), message)
    }
}
