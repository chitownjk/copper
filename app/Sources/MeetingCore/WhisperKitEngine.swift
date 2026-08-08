import Foundation
import WhisperKit

/// On-device transcription via WhisperKit (Core ML, ANE + GPU).
///
/// Replaces the `whisper-cli` subprocess and its hand-curled 1.5 GB model.
/// The loaded model is cached across meetings — loading is the expensive part —
/// and dropped when the user picks a different one.
public actor WhisperKitEngine: TranscriptionEngine {
    public static let shared = WhisperKitEngine()

    private var whisperKit: WhisperKit?
    private var loadedModelID: String?

    public nonisolated var identifier: String { "whisperkit" }
    public nonisolated var displayName: String { "Whisper (on-device)" }

    public init() {}

    public func isReady() async -> Bool {
        WhisperModelStore.isDownloaded(WhisperModelStore.selectedModelID)
    }

    /// Downloads (if needed) and loads a model, reporting 0…1 download progress.
    /// E1.3's model manager drives this from Settings and onboarding.
    @discardableResult
    public func prepare(
        modelID: String? = nil,
        allowDownload: Bool = true,
        progress: TranscriptionProgressHandler? = nil
    ) async throws -> WhisperKit {
        let modelID = modelID ?? WhisperModelStore.selectedModelID

        if let whisperKit, loadedModelID == modelID {
            return whisperKit
        }

        let isInstalled = WhisperModelStore.isDownloaded(modelID)
        guard isInstalled || allowDownload else {
            throw TranscriptionError.modelNotInstalled(modelID)
        }

        if !isInstalled {
            _ = try await WhisperKit.download(
                variant: modelID,
                downloadBase: WhisperModelStore.downloadBase,
                from: WhisperModelStore.repo,
                progressCallback: { p in
                    progress?(p.fractionCompleted)
                }
            )
        }

        // Point WhisperKit at the folder we already have so it never re-resolves
        // the model against the network on a normal launch.
        let config = WhisperKitConfig(
            model: modelID,
            downloadBase: WhisperModelStore.downloadBase,
            modelRepo: WhisperModelStore.repo,
            modelFolder: WhisperModelStore.localFolder(for: modelID).path,
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: true,
            download: false
        )

        let kit = try await WhisperKit(config)
        whisperKit = kit
        loadedModelID = modelID
        return kit
    }

    /// Frees the loaded model — used when switching models or under memory pressure.
    public func unload() {
        whisperKit = nil
        loadedModelID = nil
    }

    public func transcribe(
        audioURL: URL,
        language: String?,
        progress: TranscriptionProgressHandler?
    ) async throws -> [TranscribedSegment] {
        let kit = try await prepare(allowDownload: true, progress: progress)

        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            chunkingStrategy: .vad
        )

        let results = try await kit.transcribe(
            audioPath: audioURL.path,
            decodeOptions: options
        )

        return results
            .flatMap(\.segments)
            .map { segment in
                TranscribedSegment(
                    startMs: Int((segment.start * 1000).rounded()),
                    endMs: Int((segment.end * 1000).rounded()),
                    text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            .filter { !$0.text.isEmpty }
            .sorted { $0.startMs < $1.startMs }
    }
}
