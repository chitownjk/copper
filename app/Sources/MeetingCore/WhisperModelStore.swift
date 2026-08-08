import Foundation

public struct WhisperModel: Identifiable, Hashable, Sendable {
    /// WhisperKit variant name, as published in `argmaxinc/whisperkit-coreml`.
    public let id: String
    public let displayName: String
    public let detail: String
    public let approximateBytes: Int64

    public var approximateSizeDescription: String {
        ByteCountFormatter.string(fromByteCount: approximateBytes, countStyle: .file)
    }
}

/// Where on-device Whisper models live and which one is selected.
///
/// This is deliberately thin: download progress UI, resume, checksum validation
/// and deletion are story E1.3 and build on top of these paths.
public enum WhisperModelStore {
    public static let repo = "argmaxinc/whisperkit-coreml"

    /// Quantized large-v3-turbo — the ~600 MB accuracy/speed sweet spot (TD-2).
    public static let defaultModelID = "openai_whisper-large-v3-v20240930_turbo_632MB"

    public static let catalog: [WhisperModel] = [
        WhisperModel(
            id: "openai_whisper-base",
            displayName: "Base",
            detail: "Fastest, roughest. Fine for keyword search.",
            approximateBytes: 145_000_000
        ),
        WhisperModel(
            id: "openai_whisper-small",
            displayName: "Small",
            detail: "Good balance on 8 GB machines.",
            approximateBytes: 483_000_000
        ),
        WhisperModel(
            id: defaultModelID,
            displayName: "Large v3 Turbo",
            detail: "Recommended. Near-large accuracy at turbo speed.",
            approximateBytes: 632_000_000
        ),
        WhisperModel(
            id: "openai_whisper-large-v3_947MB",
            displayName: "Large v3",
            detail: "Most accurate, slowest. Best for noisy rooms and accents.",
            approximateBytes: 947_000_000
        )
    ]

    /// Passed to WhisperKit as its `downloadBase`; it appends `models/<repo>/<variant>`.
    public static var downloadBase: URL { Paths.modelsRoot }

    public static func localFolder(for modelID: String) -> URL {
        downloadBase
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(repo, isDirectory: true)
            .appendingPathComponent(modelID, isDirectory: true)
    }

    /// A model counts as installed once its compiled Core ML bundles are on disk.
    public static func isDownloaded(_ modelID: String) -> Bool {
        let folder = localFolder(for: modelID)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            atPath: folder.path
        ) else { return false }
        return contents.contains { $0.hasSuffix(".mlmodelc") }
    }

    public static var selectedModelID: String {
        get { UserDefaults.standard.string(forKey: "whisperModelID") ?? defaultModelID }
        set { UserDefaults.standard.set(newValue, forKey: "whisperModelID") }
    }

    public static var selectedModel: WhisperModel? {
        catalog.first { $0.id == selectedModelID }
    }

    /// Bytes currently occupied by downloaded models — surfaced in Settings (E3.4).
    public static func installedBytes() -> Int64 {
        catalog
            .filter { isDownloaded($0.id) }
            .reduce(0) { $0 + directorySize(localFolder(for: $1.id)) }
    }

    private static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
            total += Int64(size ?? 0)
        }
        return total
    }
}
