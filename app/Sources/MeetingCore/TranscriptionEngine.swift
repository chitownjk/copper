import Foundation

public struct TranscribedSegment: Equatable, Sendable {
    public let startMs: Int
    public let endMs: Int
    public let text: String

    public init(startMs: Int, endMs: Int, text: String) {
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
    }
}

/// Progress of a transcription run, 0…1. Engines that can't report meaningful
/// progress simply never call the handler.
public typealias TranscriptionProgressHandler = @Sendable (Double) -> Void

/// A source of transcripts for a mixed recording.
///
/// `WhisperKitEngine` is the primary implementation; Apple's SpeechAnalyzer
/// lands behind this same protocol in E1.4.
public protocol TranscriptionEngine: Sendable {
    /// Stable identifier persisted alongside the transcript.
    nonisolated var identifier: String { get }
    /// User-facing name for Settings.
    nonisolated var displayName: String { get }

    /// Whether the engine can transcribe right now without downloading anything.
    func isReady() async -> Bool

    /// - Parameter language: ISO 639-1 code, or `nil` to let the engine detect it.
    func transcribe(
        audioURL: URL,
        language: String?,
        progress: TranscriptionProgressHandler?
    ) async throws -> [TranscribedSegment]
}

public enum TranscriptionError: Error, LocalizedError {
    case modelNotInstalled(String)
    case engineUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .modelNotInstalled(let model):
            return "The speech model “\(model)” isn’t downloaded yet. Open Settings to download it."
        case .engineUnavailable(let reason):
            return "Transcription is unavailable: \(reason)"
        }
    }
}

/// User-facing transcription preferences. Replaces the hardcoded `-l en` the
/// whisper-cli invocation used to pass.
public enum TranscriptionSettings {
    private static let languageKey = "transcriptionLanguage"

    /// `nil` means auto-detect.
    public static var language: String? {
        get {
            let stored = UserDefaults.standard.string(forKey: languageKey) ?? "auto"
            return stored == "auto" ? nil : stored
        }
        set {
            UserDefaults.standard.set(newValue ?? "auto", forKey: languageKey)
        }
    }
}
