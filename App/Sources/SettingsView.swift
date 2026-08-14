import MeetingCore
import MeetingProviders
import SwiftUI

enum SettingsTab: String, CaseIterable {
    case camera
    case general
    case transcription
    case summaries
    case storage
}

@MainActor
@Observable
final class SettingsSession {
    var tab: SettingsTab
    init(tab: SettingsTab = .general) { self.tab = tab }
}

struct SettingsView: View {
    @Bindable var session: SettingsSession
    @State private var model = SettingsModel()
    @Environment(AppState.self) private var appState

    var body: some View {
        TabView(selection: $session.tab) {
            CameraPaneView()
                .tabItem { Label("Camera", systemImage: "video") }
                .tag(SettingsTab.camera)
            GeneralSettingsTab(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            TranscriptionSettingsTab(model: model)
                .tabItem { Label("Transcription", systemImage: "waveform") }
                .tag(SettingsTab.transcription)
            SummarizationSettingsTab(model: model)
                .tabItem { Label("Summaries", systemImage: "text.alignleft") }
                .tag(SettingsTab.summaries)
            StorageSettingsTab(model: model)
                .tabItem { Label("Storage & Privacy", systemImage: "lock.shield") }
                .tag(SettingsTab.storage)
        }
        .frame(minWidth: 560, minHeight: 520)
        .frame(width: session.tab == .camera ? 640 : 560, height: session.tab == .camera ? 720 : 540)
        .tint(Brand.accent)
        .task { await model.load() }
        .onAppear { startCameraIfNeeded() }
        .onChange(of: session.tab) { _, _ in startCameraIfNeeded() }
    }

    private func startCameraIfNeeded() {
        guard session.tab == .camera else { return }
        Task { await appState.camera.goLive() }
    }
}

// MARK: - General

struct GeneralSettingsTab: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section("Auto-record") {
                Picker("Start recording", selection: $model.autoRecordMode) {
                    ForEach(AutoRecordMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)

                Text("Auto-record arms two minutes before a calendar event and starts one minute in, so a meeting that begins late still gets captured.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Transcription

struct TranscriptionSettingsTab: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section("Engine") {
                Picker("Transcription engine", selection: $model.transcriptionEngineID) {
                    Text("Whisper (downloadable model)").tag(TranscriptionEngineID.whisperKit)
                    if model.speechAnalyzerSupported {
                        Text("Apple (no download)").tag(TranscriptionEngineID.speechAnalyzer)
                    }
                }
                Text(model.speechAnalyzerSupported
                     ? "Apple's engine starts instantly with no model download. Whisper is the accuracy option and supports auto-detecting the language."
                     : "Apple's no-download engine needs macOS 26 or later.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Language") {
                Picker("Spoken language", selection: $model.languageCode) {
                    ForEach(SettingsModel.languages, id: \.name) { language in
                        Text(language.name).tag(language.code)
                    }
                }
                Text(model.transcriptionEngineID == .speechAnalyzer
                     ? "Apple's engine can't auto-detect: it transcribes in this Mac's language unless you pick one."
                     : "Auto-detect works well for a single language per meeting. Pick one explicitly if detection guesses wrong.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Speech model") {
                ForEach(WhisperModelStore.catalog) { entry in
                    ModelRow(model: model, entry: entry)
                }
                LabeledContent("On disk", value: DiskSpace.describe(model.modelBytes))
            }
        }
        .formStyle(.grouped)
    }
}

private struct ModelRow: View {
    @Bindable var model: SettingsModel
    let entry: WhisperModel

    private var state: ModelInstallState { model.modelManager.state(of: entry.id) }
    private var isSelected: Bool { model.selectedModelID == entry.id }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                model.selectedModelID = entry.id
            } label: {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(!state.isInstalled)
            .help(state.isInstalled ? "Use this model" : "Download this model first")

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.displayName).fontWeight(.medium)
                    Text(entry.approximateSizeDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(entry.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                statusLine
            }

            Spacer()
            action
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch state {
        case .downloading(let fraction):
            ProgressView(value: fraction)
                .controlSize(.small)
                .frame(maxWidth: 180)
        case .preparing:
            Text("Preparing for the Neural Engine — this happens once.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let reason):
            Text(reason)
                .font(.caption)
                .foregroundStyle(.red)
        case .installed, .notInstalled:
            EmptyView()
        }
    }

    @ViewBuilder
    private var action: some View {
        switch state {
        case .notInstalled, .failed:
            Button("Download") {
                Task { await model.installModel(entry.id) }
            }
        case .downloading, .preparing:
            Button("Cancel") {
                model.modelManager.cancelInstall(entry.id)
            }
        case .installed:
            Button("Delete") {
                Task { await model.deleteModel(entry.id) }
            }
            .disabled(isSelected)
            .help(isSelected ? "Pick another model first" : "Remove from disk")
        }
    }
}

// MARK: - Summarization

struct SummarizationSettingsTab: View {
    @Bindable var model: SettingsModel
    @State private var editorTarget: TemplateEditorTarget?

    var body: some View {
        Form {
            Section("Default template") {
                Picker("Template", selection: $model.defaultTemplateID) {
                    ForEach(SummaryTemplateStore.all) { template in
                        Text(template.name).tag(template.id)
                    }
                }
            }

            Section("Custom templates") {
                ForEach(model.customTemplates) { template in
                    HStack {
                        Text(template.name)
                        Spacer()
                        Button {
                            editorTarget = TemplateEditorTarget(template: template)
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)
                        .help("Edit template")
                        Button {
                            model.deleteCustomTemplate(id: template.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Delete template")
                    }
                }
                if model.customTemplates.isEmpty {
                    Text("A template is a name plus the instructions the summarizer follows — e.g. “Board minutes” with your firm's format.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Add Template…") {
                    editorTarget = TemplateEditorTarget(template: nil)
                }
            }

            Section("Provider") {
                Picker("Use", selection: $model.preferredProviderID) {
                    Text("Automatic (first available)").tag(SummaryProviderID?.none)
                    ForEach(model.providerStatuses) { status in
                        Text(status.displayName).tag(SummaryProviderID?.some(status.id))
                    }
                }
                Text("Summaries are optional. With no provider configured you still get a full, searchable transcript.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(model.providerStatuses) { status in
                Section(status.displayName) {
                    ProviderStatusLine(status: status)
                    ProviderConfiguration(model: model, providerID: status.id)
                    ValidationLine(model: model, providerID: status.id)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editorTarget) { target in
            TemplateEditorSheet(model: model, editing: target.template)
        }
    }
}

private struct TemplateEditorTarget: Identifiable {
    let template: SummaryTemplate?
    var id: String { template?.id ?? "new" }
}

private struct TemplateEditorSheet: View {
    let model: SettingsModel
    let editing: SummaryTemplate?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var prompt: String = ""

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editing == nil ? "New template" : "Edit template")
                .font(.headline)

            TextField("Name", text: $name, prompt: Text("Board minutes"))

            Text("Instructions for the summarizer — tone, sections, what to ignore. The transcript is appended automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $prompt)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 180)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.quaternary))

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(editing == nil ? "Create" : "Save") {
                    model.saveCustomTemplate(id: editing?.id, name: name, prompt: prompt)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(16)
        .frame(width: 460, height: 340)
        .onAppear {
            name = editing?.name ?? ""
            prompt = editing?.systemPrompt ?? ""
        }
    }
}

private struct ProviderStatusLine: View {
    let status: SummaryProviderRegistry.Status

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: status.isReady ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(status.isReady ? .green : .secondary)
            Text(blocker)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            // Where the transcript goes is never implied — always stated.
            Label(status.privacyLabel.description, systemImage: privacyIcon)
                .font(.caption)
                .foregroundStyle(status.privacyLabel == .onDevice ? .green : .orange)
        }
    }

    private var blocker: String {
        switch status.requirement {
        case .none: return "Ready"
        case .apiKey: return "Needs an API key"
        case .serverURL: return "Needs a server URL"
        case .unavailable(let reason): return reason
        }
    }

    private var privacyIcon: String {
        status.privacyLabel == .onDevice ? "lock.fill" : "arrow.up.right.circle"
    }
}

private struct ProviderConfiguration: View {
    @Bindable var model: SettingsModel
    let providerID: SummaryProviderID

    var body: some View {
        switch providerID {
        case .appleFoundationModels:
            EmptyView()

        case .anthropic:
            Picker("Model", selection: $model.anthropicModelID) {
                ForEach(AnthropicProvider.models) { entry in
                    Text(entry.displayName).tag(entry.id)
                }
            }
            SecureField(
                "API key",
                text: $model.anthropicKey,
                prompt: Text(model.hasStoredKey(.anthropic) ? "Stored in Keychain — type to replace" : "sk-ant-…")
            )
            keyButtons(hasKey: model.hasStoredKey(.anthropic))

        case .openAI:
            Picker("Model", selection: $model.openAIModelID) {
                ForEach(OpenAIProvider.models) { entry in
                    Text(entry.displayName).tag(entry.id)
                }
            }
            SecureField(
                "API key",
                text: $model.openAIKey,
                prompt: Text(model.hasStoredKey(.openAI) ? "Stored in Keychain — type to replace" : "sk-…")
            )
            keyButtons(hasKey: model.hasStoredKey(.openAI))

        case .localServer:
            TextField("Base URL", text: $model.localServerURL, prompt: Text(LocalServerProvider.defaultBaseURL))
            TextField("Model name", text: $model.localServerModel, prompt: Text(LocalServerProvider.defaultModelName))
            HStack {
                Spacer()
                Button("Test Connection") {
                    Task { await model.saveAndValidate(providerID) }
                }
                .disabled(model.validatingProvider != nil)
            }
        }
    }

    @ViewBuilder
    private func keyButtons(hasKey: Bool) -> some View {
        HStack {
            if hasKey {
                Button("Remove Key", role: .destructive) {
                    Task { await model.removeKey(providerID) }
                }
            }
            Spacer()
            Button(hasKey ? "Save & Test" : "Save") {
                Task { await model.saveAndValidate(providerID) }
            }
            .disabled(model.validatingProvider != nil)
        }
    }
}

private struct ValidationLine: View {
    @Bindable var model: SettingsModel
    let providerID: SummaryProviderID

    var body: some View {
        if model.validatingProvider == providerID {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…").font(.caption).foregroundStyle(.secondary)
            }
        } else if let result = model.validationResults[providerID] {
            switch result {
            case .ok:
                Label("Connection verified", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}

// MARK: - Storage & Privacy

struct StorageSettingsTab: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section("Recorded audio") {
                Text("Audio is the expensive part. A 45-minute meeting can be several gigabytes. Transcripts, notes, and summaries stay; only the WAV files are swept.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Retention", selection: $model.retentionPolicy) {
                    ForEach(RetentionPolicy.allCases) { policy in
                        Text(policy.label).tag(policy)
                    }
                }
                .pickerStyle(.radioGroup)

                Text(model.retentionPolicy.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

            }

            Section("On disk") {
                LabeledContent("Recordings", value: DiskSpace.describe(model.audioBytes))
                LabeledContent("Speech models", value: DiskSpace.describe(model.modelBytes))
                if let available = DiskSpace.availableBytes() {
                    LabeledContent("Free space", value: DiskSpace.describe(available))
                }
                HStack {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.open(Paths.recordingsRoot)
                    }
                    Spacer()
                    Button("Apply Retention Now") {
                        Task { await model.sweepNow() }
                    }
                    .disabled(model.isSweeping || model.retentionPolicy == .forever)
                }
            }

            Section("Where your data goes") {
                PrivacyRow(
                    icon: "mic",
                    text: "Recording, mixing, and transcription happen entirely on this Mac."
                )
                PrivacyRow(
                    icon: "square.and.arrow.down",
                    text: "Speech models are downloaded once from Hugging Face."
                )
                PrivacyRow(
                    icon: "text.alignleft",
                    text: summaryEgressDescription
                )
            }
        }
        .formStyle(.grouped)
        .task { await model.refreshStorage() }
    }

    /// States the actual egress for the *currently selected* provider rather
    /// than a generic disclaimer.
    private var summaryEgressDescription: String {
        guard let active = model.providerStatuses.first(where: {
            model.preferredProviderID == $0.id
        }) ?? model.providerStatuses.first(where: \.isReady) else {
            return "No summarizer is configured, so nothing is sent anywhere."
        }
        switch active.privacyLabel {
        case .onDevice:
            return "Summaries are generated on-device by \(active.displayName)."
        case .sentTo(let vendor):
            return "Summaries send the transcript and your notes to \(vendor)."
        case .sentToLocalServer:
            return "Summaries send the transcript to the local server you configured."
        }
    }
}

private struct PrivacyRow: View {
    let icon: String
    let text: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
