import AVFoundation
import XCTest
@testable import MeetingCore

final class WhisperModelStoreTests: XCTestCase {
    func testDefaultModelIsTheQuantizedTurboVariant() {
        XCTAssertEqual(
            WhisperModelStore.defaultModelID,
            "openai_whisper-large-v3-v20240930_turbo_632MB"
        )
        XCTAssertTrue(WhisperModelStore.catalog.contains { $0.id == WhisperModelStore.defaultModelID })
    }

    func testLocalFolderMatchesTheHubCacheLayout() {
        let folder = WhisperModelStore.localFolder(for: "openai_whisper-base")
        XCTAssertTrue(
            folder.path.hasSuffix("models/argmaxinc/whisperkit-coreml/openai_whisper-base"),
            folder.path
        )
        XCTAssertTrue(folder.path.contains("Application Support/MeetingNotes"), folder.path)
    }

    func testUndownloadedModelIsNotReportedAsInstalled() {
        XCTAssertFalse(WhisperModelStore.isDownloaded("openai_whisper-not-a-real-model"))
    }
}

final class TranscriptionSettingsTests: XCTestCase {
    private var original: String?

    override func setUp() {
        original = UserDefaults.standard.string(forKey: "transcriptionLanguage")
    }

    override func tearDown() {
        UserDefaults.standard.set(original, forKey: "transcriptionLanguage")
    }

    func testDefaultsToAutoDetect() {
        UserDefaults.standard.removeObject(forKey: "transcriptionLanguage")
        XCTAssertNil(TranscriptionSettings.language, "language must default to auto-detect, not hardcoded en")
    }

    func testRoundTripsAnExplicitLanguage() {
        TranscriptionSettings.language = "de"
        XCTAssertEqual(TranscriptionSettings.language, "de")
        TranscriptionSettings.language = nil
        XCTAssertNil(TranscriptionSettings.language)
    }
}

/// End-to-end transcription against the real recording. Downloads ~632 MB the
/// first time, so it only runs when asked:
///
///     MEETING_NOTES_RUN_TRANSCRIPTION=1 swift test --filter WhisperKitEngineIntegrationTests
final class WhisperKitEngineIntegrationTests: XCTestCase {
    func testTranscribesTheSampleRecording() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MEETING_NOTES_RUN_TRANSCRIPTION"] == "1",
            "Set MEETING_NOTES_RUN_TRANSCRIPTION=1 to run the end-to-end transcription test."
        )
        let dir = try AudioMixerGoldenTests.fixtureDirectory()

        let mixed = FileManager.default.temporaryDirectory
            .appendingPathComponent("e2e-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: mixed) }
        try AudioMixer.mixSynchronously(
            inputs: [
                dir.appendingPathComponent("system.wav"),
                dir.appendingPathComponent("mic.wav")
            ],
            outputURL: mixed
        )

        let engine = WhisperKitEngine()
        let started = Date()
        let segments = try await engine.transcribe(audioURL: mixed, language: "en", progress: nil)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertFalse(segments.isEmpty, "no segments produced")

        let audioSeconds = Double(try AVAudioFile(forReading: mixed).length) / AudioMixer.sampleRate
        for (index, segment) in segments.enumerated() {
            XCTAssertLessThanOrEqual(segment.startMs, segment.endMs, "segment \(index) ends before it starts")
            XCTAssertGreaterThanOrEqual(segment.startMs, 0)
            XCTAssertLessThanOrEqual(
                Double(segment.endMs) / 1000,
                audioSeconds + 0.5,
                "segment \(index) runs past the end of the audio"
            )
            if index > 0 {
                XCTAssertGreaterThanOrEqual(
                    segment.startMs,
                    segments[index - 1].startMs,
                    "segments must be ordered"
                )
            }
        }

        // Content check against the transcript the whisper-cli path produced.
        // The bundled fixture is the 4.0–12.16 s slice of that recording.
        let transcript = segments.map(\.text).joined(separator: " ").lowercased()
        for phrase in ["speaking into the mic", "grab some other audio"] {
            XCTAssertTrue(transcript.contains(phrase), "expected “\(phrase)” in:\n\(transcript)")
        }

        print("""
        Transcribed \(String(format: "%.1f", audioSeconds)) s of audio in \
        \(String(format: "%.1f", elapsed)) s → \(segments.count) segments
        \(segments.map { "[\($0.startMs)–\($0.endMs)] \($0.text)" }.joined(separator: "\n"))
        """)
    }
}
