import AVFoundation
import XCTest
@testable import MeetingCore

/// Exercises Apple's SpeechAnalyzer against the real bundled recording.
///
/// Unlike the WhisperKit integration test this is NOT gated behind an env
/// var: there is no 632 MB download, only a small OS-managed locale asset.
/// It skips itself below macOS 26 or when the locale isn't supported.
final class SpeechAnalyzerEngineTests: XCTestCase {
    func testEngineSelectionFallsBackToWhisperWhenUnsupported() {
        let original = UserDefaults.standard.string(forKey: "transcriptionEngine")
        defer { UserDefaults.standard.set(original, forKey: "transcriptionEngine") }

        TranscriptionSettings.engineID = .whisperKit
        XCTAssertEqual(TranscriptionEngines.current().identifier, "whisperkit")

        TranscriptionSettings.engineID = .speechAnalyzer
        let resolved = TranscriptionEngines.current().identifier
        if SpeechAnalyzerEngine.isSupportedOnThisOS {
            XCTAssertEqual(resolved, "speechanalyzer")
        } else {
            XCTAssertEqual(resolved, "whisperkit", "stale preference must fall back, not fail")
        }
    }

    func testTranscribesTheSampleRecording() async throws {
        let engine = SpeechAnalyzerEngine()
        guard SpeechAnalyzerEngine.isSupportedOnThisOS, await engine.isReady() else {
            throw XCTSkip("SpeechAnalyzer unavailable on this machine")
        }

        let dir = try AudioMixerGoldenTests.fixtureDirectory()
        let mixed = FileManager.default.temporaryDirectory
            .appendingPathComponent("sa-e2e-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: mixed) }
        try AudioMixer.mixSynchronously(
            inputs: [
                dir.appendingPathComponent("system.wav"),
                dir.appendingPathComponent("mic.wav")
            ],
            outputURL: mixed
        )

        let started = Date()
        let segments = try await engine.transcribe(audioURL: mixed, language: "en", progress: nil)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertFalse(segments.isEmpty, "no segments produced")

        // Same schema and timestamp discipline the WhisperKit engine is held to.
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
                XCTAssertGreaterThanOrEqual(segment.startMs, segments[index - 1].startMs, "segments must be ordered")
            }
        }

        // Content bar calibrated to what both engines get right on this slice.
        // Measured divergence (Aug 2026, macOS 26.5.2): the recording's last
        // word is clipped by the fixture boundary; Whisper hears "grab some
        // other audio" (correct), SpeechAnalyzer hears "…audience". TD-2's
        // quality ranking (between whisper-small and large) is real.
        let transcript = segments.map(\.text).joined(separator: " ").lowercased()
        for phrase in ["speaking into the mic", "grab some other"] {
            XCTAssertTrue(transcript.contains(phrase), "expected “\(phrase)” in:\n\(transcript)")
        }

        print("""
        SpeechAnalyzer transcribed \(String(format: "%.1f", audioSeconds)) s in \
        \(String(format: "%.1f", elapsed)) s → \(segments.count) segments
        \(segments.map { "[\($0.startMs)–\($0.endMs)] \($0.text)" }.joined(separator: "\n"))
        """)
    }
}
