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

    /// Stored so @Observable publishes the radio change immediately.
    /// A computed UserDefaults passthrough writes the value but never
    /// invalidates the Picker, so the selected radio stayed stale until
    /// the pane was rebuilt.
    var autoRecordMode: AutoRecordMode = AutoRecordSettings.current {
        didSet { AutoRecordSettings.current = autoRecordMode }
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

    // Stored so the picker / toggle redraw immediately (same reason as autoRecordMode).
    var dictationPreset: DictationChordPreset = DictationHotkeySettings.preset {
        didSet { DictationHotkeySettings.preset = dictationPreset }
    }

    var dictationAlsoFnAlone: Bool = DictationHotkeySettings.alsoFnAlone {
        didSet { DictationHotkeySettings.alsoFnAlone = dictationAlsoFnAlone }
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

    /// Stored so @Observable publishes the picker change immediately.
    /// A computed UserDefaults passthrough writes the value but never
    /// invalidates the Picker — same class of bug as autoRecordMode.
    var defaultTemplateID: String = SummaryTemplateStore.selected.id {
        didSet {
            if let template = SummaryTemplateStore.template(id: defaultTemplateID) {
                SummaryTemplateStore.selected = template
            }
        }
    }

    // MARK: Templates (E2.5 editor + built-in rewrites)

    // Stored (not computed from UserDefaults) so @Observable actually
    // refreshes the Settings list after a save/delete/reset.
    private(set) var customTemplates: [SummaryTemplate] = SummaryTemplateStore.custom
    private(set) var builtInTemplates: [SummaryTemplate] = SummaryTemplateStore.builtInsResolved
    private(set) var allTemplates: [SummaryTemplate] = SummaryTemplateStore.all

    private func refreshTemplates() {
        customTemplates = SummaryTemplateStore.custom
        builtInTemplates = SummaryTemplateStore.builtInsResolved
        allTemplates = SummaryTemplateStore.all
    }

    func isBuiltInOverridden(id: String) -> Bool {
        SummaryTemplateStore.isBuiltInOverridden(id: id)
    }

    /// `id == nil` creates; otherwise updates in place.
    func saveCustomTemplate(id: String?, name: String, prompt: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedPrompt.isEmpty else { return }

        var templates = SummaryTemplateStore.custom
        if let id, let index = templates.firstIndex(where: { $0.id == id }) {
            templates[index] = SummaryTemplate(id: id, name: trimmedName, systemPrompt: trimmedPrompt)
        } else {
            templates.append(SummaryTemplate(
                id: "custom-\(UUID().uuidString.lowercased())",
                name: trimmedName,
                systemPrompt: trimmedPrompt
            ))
        }
        SummaryTemplateStore.custom = templates
        refreshTemplates()
    }

    func deleteCustomTemplate(id: String) {
        SummaryTemplateStore.custom.removeAll { $0.id == id }
        refreshTemplates()
        // A deleted default silently becoming "general" at summarize time
        // would be confusing — make the fallback visible immediately.
        if SummaryTemplateStore.template(id: defaultTemplateID) == nil {
            defaultTemplateID = SummaryTemplate.general.id
        }
    }

    func saveBuiltInOverride(id: String, name: String, prompt: String) {
        SummaryTemplateStore.saveBuiltInOverride(id: id, name: name, systemPrompt: prompt)
        refreshTemplates()
    }

    func resetBuiltInTemplate(id: String) {
        SummaryTemplateStore.resetBuiltInOverride(id: id)
        refreshTemplates()
    }

    enum ValidationOutcome: Equatable {
        case ok
        case failed(String)
    }

    /// Per-provider result of the last "Test connection" / key save.
    var validationResults: [SummaryProviderID: ValidationOutcome] = [:]
    var validatingProvider: SummaryProviderID?

    // MARK: Storage

    /// Stored so the radio publishes immediately. A UserDefaults
    /// passthrough wrote the value but left the Picker looking stale
    /// until the window was closed and reopened.
    var retentionPolicy: RetentionPolicy = RetentionSettings.policy {
        didSet { RetentionSettings.policy = retentionPolicy }
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
        retentionPolicy = RetentionSettings.policy
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
        case .localServer:
            KeychainStore.remove(.localServer)
            LocalServerProvider.clearProbe()
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
