import Foundation
import Observation

public enum ModelInstallState: Equatable, Sendable {
    case notInstalled
    /// 0…1 of bytes fetched. Interrupted downloads resume from where they
    /// stopped, so this can start above zero on a retry.
    case downloading(fraction: Double)
    /// Downloaded; Core ML is specializing the model for this Mac's ANE.
    case preparing
    case installed(bytes: Int64)
    case failed(String)

    public var isBusy: Bool {
        switch self {
        case .downloading, .preparing: return true
        default: return false
        }
    }

    public var isInstalled: Bool {
        if case .installed = self { return true }
        return false
    }
}

/// Owns the lifecycle of on-device speech models: install, verify, delete, and
/// the ANE warm-up that decides whether the user's first meeting takes three
/// seconds or four minutes (E1.3).
///
/// Byte-range resume and SHA-256 verification of each downloaded file are
/// handled beneath us by the Hugging Face client WhisperKit embeds — a retry
/// after a network drop continues from the partial file rather than restarting,
/// and a file whose hash doesn't match its etag is re-fetched. What this type
/// adds is the layer above: whether the *model as a whole* is complete and
/// loadable, and a UI-observable state for each catalog entry.
@MainActor
@Observable
public final class WhisperModelManager {
    public static let shared = WhisperModelManager()

    public private(set) var states: [String: ModelInstallState] = [:]
    private var installTasks: [String: Task<Void, Never>] = [:]

    public init() {
        refresh()
    }

    public func state(of modelID: String) -> ModelInstallState {
        states[modelID] ?? .notInstalled
    }

    /// Re-reads the disk. Cheap; safe to call whenever Settings appears.
    public func refresh() {
        for model in WhisperModelStore.catalog {
            // Don't stomp on an install in flight.
            if states[model.id]?.isBusy == true { continue }
            states[model.id] = WhisperModelStore.isDownloaded(model.id)
                ? .installed(bytes: WhisperModelStore.installedBytes(of: model.id))
                : .notInstalled
        }
    }

    public var totalInstalledBytes: Int64 {
        WhisperModelStore.installedBytes()
    }

    // MARK: - Install

    /// Downloads if needed, verifies the result, then prewarms so Core ML pays
    /// its specialization cost here rather than during the first real meeting.
    ///
    /// Re-entrant: calling this for a model already installing joins the
    /// existing task instead of starting a second download.
    public func install(_ modelID: String, prewarm: Bool = true) async {
        if let existing = installTasks[modelID] {
            await existing.value
            return
        }

        let task = Task { @MainActor [weak self] () -> Void in
            await self?.performInstall(modelID, prewarm: prewarm)
        }
        installTasks[modelID] = task
        await task.value
        installTasks[modelID] = nil
    }

    private func performInstall(_ modelID: String, prewarm: Bool) async {
        states[modelID] = .downloading(fraction: 0)

        do {
            try await WhisperKitEngine.shared.prepare(
                modelID: modelID,
                allowDownload: true,
                prewarm: prewarm,
                progress: { [weak self] fraction in
                    Task { @MainActor in
                        // Once bytes are in, the remaining wait is Core ML
                        // specialization, which reports no progress of its own.
                        self?.states[modelID] = fraction >= 1.0
                            ? .preparing
                            : .downloading(fraction: fraction)
                    }
                }
            )

            guard case .complete = verify(modelID) else {
                let detail = verify(modelID).description
                states[modelID] = .failed(detail)
                return
            }
            states[modelID] = .installed(bytes: WhisperModelStore.installedBytes(of: modelID))
        } catch is CancellationError {
            // Partial files stay on disk; the next install resumes from them.
            refresh()
        } catch {
            states[modelID] = .failed(error.localizedDescription)
        }
    }

    /// Stops an install. Downloaded bytes are deliberately left in place so a
    /// later retry resumes rather than starting over.
    public func cancelInstall(_ modelID: String) {
        installTasks[modelID]?.cancel()
        installTasks[modelID] = nil
        refresh()
    }

    // MARK: - Verify

    public enum Integrity: Equatable {
        case complete
        case missing
        /// Downloaded but unusable — an interrupted or corrupted install.
        case incomplete(reason: String)

        var description: String {
            switch self {
            case .complete: return "Complete."
            case .missing: return "Not downloaded."
            case .incomplete(let reason): return reason
            }
        }
    }

    /// Structural check that the model is actually loadable, which is what a
    /// half-finished download really breaks. Per-file hashes were already
    /// verified during download; this catches the case where some files never
    /// arrived at all.
    public func verify(_ modelID: String) -> Integrity {
        let folder = WhisperModelStore.localFolder(for: modelID)
        let fileManager = FileManager.default

        guard let entries = try? fileManager.contentsOfDirectory(atPath: folder.path) else {
            return .missing
        }

        let compiled = entries.filter { $0.hasSuffix(".mlmodelc") }
        // A Whisper conversion always ships at least the mel front-end, the
        // audio encoder, and the text decoder.
        guard compiled.count >= 3 else {
            return .incomplete(reason: "Only \(compiled.count) of the model's components are present.")
        }

        for bundle in compiled {
            let marker = folder.appendingPathComponent(bundle).appendingPathComponent("coremldata.bin")
            guard fileManager.fileExists(atPath: marker.path) else {
                return .incomplete(reason: "\(bundle) is missing its compiled weights.")
            }
        }

        guard fileManager.fileExists(atPath: folder.appendingPathComponent("config.json").path) else {
            return .incomplete(reason: "The model's config.json is missing.")
        }

        if hasPartialDownloads() {
            return .incomplete(reason: "A previous download didn’t finish.")
        }

        return .complete
    }

    /// The Hub client parks in-flight files as `*.incomplete` beside a `.cache`
    /// sidecar; any left over means a download was interrupted.
    private func hasPartialDownloads() -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: WhisperModelStore.downloadBase,
            includingPropertiesForKeys: nil
        ) else { return false }
        for case let url as URL in enumerator where url.pathExtension == "incomplete" {
            return true
        }
        return false
    }

    // MARK: - Delete

    /// Removes a model from disk. Frees the selected model from memory first so
    /// we aren't deleting files out from under a loaded Core ML model.
    public func delete(_ modelID: String) async throws {
        cancelInstall(modelID)
        if WhisperModelStore.selectedModelID == modelID {
            await WhisperKitEngine.shared.unload()
        }
        try FileManager.default.removeItem(at: WhisperModelStore.localFolder(for: modelID))
        states[modelID] = .notInstalled
    }

    /// Clears interrupted downloads so a retry starts clean. Only worth
    /// offering when a resume keeps failing.
    public func clearPartialDownloads() throws {
        let base = WhisperModelStore.downloadBase
        guard let enumerator = FileManager.default.enumerator(
            at: base,
            includingPropertiesForKeys: nil
        ) else { return }
        for case let url as URL in enumerator where url.pathExtension == "incomplete" {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
