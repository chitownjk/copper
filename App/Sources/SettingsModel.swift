import Foundation
import MeetingCore
import MeetingProviders
import Observation

/// Backing state for the Settings window (E3.4).
///
/// Everything here is a thin adapter over the stores that already own the
/// values — `UserDefaults`, the Keychain, `WhisperModelManager`. Nothing is
/// cached, so a change made anywhere takes effect without a restart.
@MainActor
@Observable
final class SettingsModel {
    // MARK: General

    var autoRecordMode: AutoRecordMode {
        get { AutoRecordSettings.current }
        set { AutoRecordSettings.current = newValue }
    }

    // MARK: Transcription

    let modelManager = WhisperModelManager.shared

    var transcriptionEngineID: TranscriptionEngineID {
        get { TranscriptionSettings.engineID }
        set { TranscriptionSettings.engineID = newValue }
    }

    /// Whether this Mac has Apple's SpeechAnalyzer engine at all (macOS 26+).
    let speechAnalyzerSupported = SpeechAnalyzerEngine.isSupportedOnThisOS

    var selectedModelID: String {
        get { WhisperModelStore.selectedModelID }
        set {
            WhisperModelStore.selectedModelID = newValue
            Task { await WhisperKitEngine.shared.unload() }
        }
    }

    /// `nil` is auto-detect. Kept short deliberately — a long list of languages
    /// nobody uses is worse than auto plus the ones we've verified.
    static let languages: [(code: String?, name: String)] = [
        (nil, "Auto-detect"),
        ("en", "English"),
        ("es", "Spanish"),
        ("fr", "French"),
        ("de", "German"),
        ("pt", "Portuguese"),
        ("it", "Italian"),
        ("nl", "Dutch"),
        ("ja", "Japanese"),
        ("zh", "Chinese"),
        ("ko", "Korean")
    ]

    var languageCode: String? {
        get { TranscriptionSettings.language }
        set { TranscriptionSettings.language = newValue }
    }

    // MARK: Summarization

    var providerStatuses: [SummaryProviderRegistry.Status] = []
    var preferredProviderID: SummaryProviderID? {
        get { SummaryProviderRegistry.shared.preferredID }
        set {
            SummaryProviderRegistry.shared.preferredID = newValue
            Task { await refreshProviders() }
        }
    }

    var anthropicKey = ""
    var openAIKey = ""
    var localServerURL = LocalServerProvider.baseURLString
    var localServerModel = LocalServerProvider.modelName

    var anthropicModelID: String {
        get { AnthropicProvider.selectedModelID }
        set { AnthropicProvider.selectedModelID = newValue }
    }

    var openAIModelID: String {
        get { OpenAIProvider.selectedModelID }
        set { OpenAIProvider.selectedModelID = newValue }
    }

    var defaultTemplateID: String {
        get { SummaryTemplateStore.selected.id }
        set {
            if let template = SummaryTemplateStore.template(id: newValue) {
                SummaryTemplateStore.selected = template
            }
        }
    }

    enum ValidationOutcome: Equatable {
        case ok
        case failed(String)
    }

    /// Per-provider result of the last "Test connection" / key save.
    var validationResults: [SummaryProviderID: ValidationOutcome] = [:]
    var validatingProvider: SummaryProviderID?

    // MARK: Storage

    var retentionPolicy: RetentionPolicy {
        get { RetentionSettings.policy }
        set { RetentionSettings.policy = newValue }
    }

    var audioBytes: Int64 = 0
    var modelBytes: Int64 = 0
    var isSweeping = false

    // MARK: - Loading

    func load() async {
        // Keychain values are never rendered back — an empty field means
        // "a key is stored", and typing replaces it.
        anthropicKey = ""
        openAIKey = ""
        localServerURL = LocalServerProvider.baseURLString
        localServerModel = LocalServerProvider.modelName
        modelManager.refresh()
        modelBytes = modelManager.totalInstalledBytes
        await refreshProviders()
        await refreshStorage()
    }

    func refreshProviders() async {
        providerStatuses = await SummaryProviderRegistry.shared.statuses()
    }

    func refreshStorage() async {
        audioBytes = await RetentionSweeper.totalAudioBytes()
        modelBytes = modelManager.totalInstalledBytes
    }

    func hasStoredKey(_ account: KeychainStore.Account) -> Bool {
        KeychainStore.has(account)
    }

    // MARK: - Actions

    /// Saves a key and immediately proves it works, so a typo surfaces here
    /// rather than after the next meeting (E2.3 acceptance criteria).
    func saveAndValidate(_ providerID: SummaryProviderID) async {
        validatingProvider = providerID
        defer { validatingProvider = nil }

        switch providerID {
        case .anthropic:
            if !anthropicKey.isEmpty {
                KeychainStore.set(anthropicKey.trimmingCharacters(in: .whitespaces), for: .anthropic)
                anthropicKey = ""
            }
        case .openAI:
            if !openAIKey.isEmpty {
                KeychainStore.set(openAIKey.trimmingCharacters(in: .whitespaces), for: .openAI)
                openAIKey = ""
            }
        case .localServer:
            LocalServerProvider.baseURLString = localServerURL.trimmingCharacters(in: .whitespaces)
            LocalServerProvider.modelName = localServerModel.trimmingCharacters(in: .whitespaces)
        case .appleFoundationModels:
            break
        }

        guard let provider = SummaryProviderRegistry.shared.provider(for: providerID) else { return }
        do {
            try await provider.validateConfiguration()
            validationResults[providerID] = .ok
        } catch {
            validationResults[providerID] = .failed(error.localizedDescription)
        }
        await refreshProviders()
    }

    func removeKey(_ providerID: SummaryProviderID) async {
        switch providerID {
        case .anthropic: KeychainStore.remove(.anthropic)
        case .openAI: KeychainStore.remove(.openAI)
        case .localServer: KeychainStore.remove(.localServer)
        case .appleFoundationModels: break
        }
        validationResults[providerID] = nil
        await refreshProviders()
    }

    func installModel(_ modelID: String) async {
        await modelManager.install(modelID)
        await refreshStorage()
    }

    func deleteModel(_ modelID: String) async {
        try? await modelManager.delete(modelID)
        await refreshStorage()
    }

    func sweepNow() async {
        isSweeping = true
        defer { isSweeping = false }
        let result = await RetentionSweeper.sweep()
        RetentionSettings.lastSweep = Date()
        await refreshStorage()
        ToastPresenter.shared.show(
            .info,
            title: result.meetingsSwept == 0 ? "Nothing to delete" : "Reclaimed \(DiskSpace.describe(result.bytesReclaimed))",
            subtitle: result.meetingsSwept == 0
                ? "No meetings are past the retention window."
                : "Audio removed from \(result.meetingsSwept) meeting\(result.meetingsSwept == 1 ? "" : "s")."
        )
    }
}
