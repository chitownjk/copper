import Foundation
import AVFoundation
#if canImport(Speech)
import Speech
#endif

/// Transcription via Apple's SpeechAnalyzer/SpeechTranscriber (macOS 26+).
///
/// The "instant start" engine (TD-2): no 632 MB model download — the OS
/// manages small per-locale assets itself. Quality sits between whisper-small
/// and whisper-large; WhisperKit remains the accuracy option.
///
/// Unlike Whisper there is no language auto-detection: a transcriber is
/// created for one locale. `language == nil` therefore means the system
/// locale, which is right for the overwhelmingly common case of people whose
/// meetings are in their Mac's language.
public struct SpeechAnalyzerEngine: TranscriptionEngine {
    public nonisolated var identifier: String { "speechanalyzer" }
    public nonisolated var displayName: String { "Apple (no download)" }

    public init() {}

    /// Whether SpeechAnalyzer exists on this OS at all.
    public static var isSupportedOnThisOS: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    public func isReady() async -> Bool {
        #if canImport(Speech)
        guard #available(macOS 26, *) else { return false }
        let locale = Self.locale(for: TranscriptionSettings.language)
        return await Self.supports(locale: locale)
        #else
        return false
        #endif
    }

    public func transcribe(
        audioURL: URL,
        language: String?,
        progress: TranscriptionProgressHandler?
    ) async throws -> [TranscribedSegment] {
        #if canImport(Speech)
        guard #available(macOS 26, *) else {
            throw TranscriptionError.engineUnavailable("Apple's transcription engine needs macOS 26 or later.")
        }
        return try await Self.run(audioURL: audioURL, language: language, progress: progress)
        #else
        throw TranscriptionError.engineUnavailable("This build wasn’t compiled with SpeechAnalyzer support.")
        #endif
    }

    static func locale(for language: String?) -> Locale {
        guard let language, !language.isEmpty else { return Locale.current }
        return Locale(identifier: language)
    }

    #if canImport(Speech)
    /// Maps a requested locale (possibly a bare language code like "en") onto
    /// one the transcriber actually supports ("en-US", …). The transcriber
    /// rejects under-specified locales with "Unable to reserve unsupported
    /// locale", so this resolution is mandatory, not cosmetic.
    @available(macOS 26, *)
    private static func resolveSupportedLocale(for locale: Locale) async -> Locale? {
        let supported = await SpeechTranscriber.supportedLocales
        if let exact = supported.first(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            return exact
        }
        let sameLanguage = supported.filter { $0.language.languageCode == locale.language.languageCode }
        if let regional = sameLanguage.first(where: { $0.region == Locale.current.region }) {
            return regional
        }
        return sameLanguage.first
    }

    @available(macOS 26, *)
    private static func supports(locale: Locale) async -> Bool {
        await resolveSupportedLocale(for: locale) != nil
    }

    @available(macOS 26, *)
    private static func run(
        audioURL: URL,
        language: String?,
        progress: TranscriptionProgressHandler?
    ) async throws -> [TranscribedSegment] {
        let requested = locale(for: language)
        guard let locale = await resolveSupportedLocale(for: requested) else {
            throw TranscriptionError.engineUnavailable(
                "Apple's transcription engine doesn’t support “\(requested.identifier)”. Use the Whisper engine for this language."
            )
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )

        // Per-locale assets are downloaded once by the OS (tens of MB, not
        // ours to manage). No-op when already installed.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        let audioFile = try AVAudioFile(forReading: audioURL)
        let audioSeconds = Double(audioFile.length) / audioFile.processingFormat.sampleRate

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Collect results concurrently with feeding the file; the stream ends
        // when the analyzer finishes.
        let collector = Task {
            var segments: [TranscribedSegment] = []
            for try await result in transcriber.results where result.isFinal {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }

                var startSeconds: Double?
                var endSeconds: Double?
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let start = range.start.seconds
                    let end = range.end.seconds
                    startSeconds = min(startSeconds ?? start, start)
                    endSeconds = max(endSeconds ?? end, end)
                }
                // A result with no attributed time ranges falls back to the
                // result's own range.
                let start = startSeconds ?? result.range.start.seconds
                let end = endSeconds ?? result.range.end.seconds

                segments.append(TranscribedSegment(
                    startMs: Int((start * 1000).rounded()),
                    endMs: Int((end * 1000).rounded()),
                    text: text
                ))
                if audioSeconds > 0 {
                    progress?(min(1.0, end / audioSeconds))
                }
            }
            return segments
        }

        do {
            if let lastSampleTime = try await analyzer.analyzeSequence(from: audioFile) {
                try await analyzer.finalizeAndFinish(through: lastSampleTime)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            throw error
        }

        let segments = try await collector.value
        return segments.sorted { $0.startMs < $1.startMs }
    }
    #endif
}
