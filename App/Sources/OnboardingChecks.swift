import Foundation
import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import EventKit
import MeetingCore
import MeetingProviders
import Speech

enum CheckStatus {
    case ok
    case missing
    case denied
    case unknown
}

struct CheckItem: Identifiable {
    let id: String
    let title: String
    let detail: String
    let status: CheckStatus
    let action: CheckAction?
    var isRequired: Bool = true
}

enum CheckAction {
    case requestMic
    case requestCamera
    case requestAccessibility
    case requestSpeech
    case openScreenRecordingSettings
    case requestCalendar
    case openInternetAccounts
    case installCameraExtension
    case downloadSpeechModel
}

@MainActor
@Observable
final class OnboardingChecks {
    var items: [CheckItem] = []
    /// 0…1 while the speech model is downloading, `nil` otherwise.
    var modelDownloadProgress: Double?
    /// The summarization backend that would run right now, if any.
    var readySummarizer: SummaryProviderRegistry.Status?
    private weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
        refresh()
        Task { await refreshSummarizer() }
    }

    func refreshSummarizer() async {
        let statuses = await SummaryProviderRegistry.shared.statuses()
        readySummarizer = statuses.first(where: \.isReady)
        refresh()
    }

    var allPass: Bool {
        items.filter(\.isRequired).allSatisfy { $0.status == .ok }
    }

    func refresh() {
        var refreshed = [
            micCheck(),
            accessibilityCheck(),
            cameraCheck(),
            cameraExtensionCheck(),
            screenRecordingCheck(),
            calendarCheck(),
            internetAccountsCheck(),
            modelCheck(),
            summarizerCheck()
        ]
        if let speech = speechPermissionCheck() {
            refreshed.insert(speech, afterID: "mic")
        }
        items = refreshed
    }

    // MARK: - Individual checks

    private func micCheck() -> CheckItem {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        let cs: CheckStatus
        switch status {
        case .authorized:    cs = .ok
        case .denied, .restricted: cs = .denied
        case .notDetermined: cs = .unknown
        @unknown default:    cs = .unknown
        }
        return CheckItem(
            id: "mic",
            title: "Microphone access",
            detail: "Required to capture your voice during in-person meetings.",
            status: cs,
            action: cs == .ok ? nil : .requestMic
        )
    }

    private func cameraCheck() -> CheckItem {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        let cs: CheckStatus
        switch status {
        case .authorized: cs = .ok
        case .denied, .restricted: cs = .denied
        case .notDetermined: cs = .unknown
        @unknown default: cs = .unknown
        }
        return CheckItem(
            id: "camera",
            title: "Camera access",
            detail: "Optional. Needed only for Copper Camera’s live feed and five-second Camera Off loop.",
            status: cs,
            action: cs == .ok ? nil : .requestCamera,
            isRequired: false
        )
    }

    private func accessibilityCheck() -> CheckItem {
        let trusted = AXIsProcessTrusted()
        return CheckItem(
            id: "accessibility",
            title: "Accessibility access",
            detail: "Required for the dictation hotkey to insert text into other apps.",
            status: trusted ? .ok : .denied,
            action: trusted ? nil : .requestAccessibility
        )
    }

    private func speechPermissionCheck() -> CheckItem? {
        guard TranscriptionSettings.engineID == .speechAnalyzer,
              SpeechAnalyzerEngine.isSupportedOnThisOS else {
            return nil
        }
        let status = SFSpeechRecognizer.authorizationStatus()
        let cs: CheckStatus
        switch status {
        case .authorized: cs = .ok
        case .denied, .restricted: cs = .denied
        case .notDetermined: cs = .unknown
        @unknown default: cs = .unknown
        }
        return CheckItem(
            id: "speech",
            title: "Speech Recognition access",
            detail: "Required for the selected Apple Speech transcription engine.",
            status: cs,
            action: cs == .ok ? nil : .requestSpeech
        )
    }

    private func cameraExtensionCheck() -> CheckItem {
        let installed = CameraSinkClient.isVirtualCameraInstalled
        return CheckItem(
            id: "camera-extension",
            title: "Copper Camera extension",
            detail: installed
                ? "Ready — Copper Camera is available to Meet, Zoom, and other camera apps."
                : "Optional. Install or repair it, then approve Camera Extensions in System Settings → General → Login Items & Extensions.",
            status: installed ? .ok : .missing,
            action: installed ? nil : .installCameraExtension,
            isRequired: false
        )
    }

    private func screenRecordingCheck() -> CheckItem {
        let granted = CGPreflightScreenCaptureAccess()
        return CheckItem(
            id: "screen",
            title: "Screen Recording (system audio)",
            detail: "Required to capture audio from Zoom/Meet/Teams. Toggled in System Settings → Privacy & Security → Screen Recording.",
            status: granted ? .ok : .denied,
            action: granted ? nil : .openScreenRecordingSettings,
            isRequired: false
        )
    }

    private func calendarCheck() -> CheckItem {
        let status = EKEventStore.authorizationStatus(for: .event)
        let cs: CheckStatus
        switch status {
        case .fullAccess, .authorized, .writeOnly: cs = .ok
        case .denied, .restricted:                  cs = .denied
        case .notDetermined:                        cs = .unknown
        @unknown default:                           cs = .unknown
        }
        return CheckItem(
            id: "calendar",
            title: "Calendar access",
            detail: "Optional. Companion reads Apple Calendar so it can list this week and auto-record. There is no Google sign-in in this app.",
            status: cs,
            action: cs == .ok ? nil : .requestCalendar,
            isRequired: false
        )
    }

    /// Informational — always ready so it does not block the checklist.
    private func internetAccountsCheck() -> CheckItem {
        CheckItem(
            id: "internet-accounts",
            title: "Google or Outlook calendars",
            detail: "Add the account in System Settings → Internet Accounts. Companion then sees those events through Apple Calendar.",
            status: .ok,
            action: .openInternetAccounts,
            isRequired: false
        )
    }

    /// Optional by design: with no summarizer the pipeline still produces a
    /// searchable transcript (E1.6), so this is a nudge, never a blocker.
    private func summarizerCheck() -> CheckItem {
        let detail: String
        if let ready = readySummarizer {
            detail = "\(ready.displayName) — \(ready.privacyLabel.description)."
        } else {
            detail = "Optional. Without one you still get transcripts and search; "
                + "add Apple Intelligence, an API key, or a local server in Settings to get summaries."
        }
        return CheckItem(
            id: "summarizer",
            title: "Summarizer",
            detail: detail,
            status: readySummarizer == nil ? .unknown : .ok,
            action: nil,
            isRequired: false
        )
    }

    private func modelCheck() -> CheckItem {
        if TranscriptionSettings.engineID == .speechAnalyzer,
           SpeechAnalyzerEngine.isSupportedOnThisOS {
            return CheckItem(
                id: "model",
                title: "Apple Speech transcription",
                detail: "Ready — the selected engine does not require a Whisper model download.",
                status: .ok,
                action: nil
            )
        }
        let model = WhisperModelStore.selectedModel
        let modelID = WhisperModelStore.selectedModelID
        let name = model?.displayName ?? modelID
        let installed = WhisperModelStore.isDownloaded(modelID)

        let detail: String
        if let progress = modelDownloadProgress {
            detail = "Downloading… \(Int(progress * 100))%"
        } else if installed {
            detail = "Ready — \(name) is on this Mac."
        } else {
            let size = model?.approximateSizeDescription ?? "~600 MB"
            detail = "Not downloaded yet (\(size)). Downloads in the background — no Terminal needed."
        }

        return CheckItem(
            id: "model",
            title: "Speech model (\(name))",
            detail: detail,
            status: installed ? .ok : .missing,
            action: installed || modelDownloadProgress != nil ? nil : .downloadSpeechModel
        )
    }

    // MARK: - Actions

    func perform(_ action: CheckAction) async {
        switch action {
        case .requestMic:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .requestCamera:
            _ = await AVCaptureDevice.requestAccess(for: .video)
        case .requestAccessibility:
            DictationPermissions.promptAccessibility()
            DictationPermissions.openAccessibilitySettings()
        case .requestSpeech:
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { _ in
                    continuation.resume()
                }
            }
        case .openScreenRecordingSettings:
            CGRequestScreenCaptureAccess()
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        case .requestCalendar:
            await appState?.requestCalendarAccess()
        case .openInternetAccounts:
            InternetAccountsOpener.open()
        case .installCameraExtension:
            CameraExtensionInstaller.install { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        case .downloadSpeechModel:
            await downloadSpeechModel()
        }
        refresh()
    }

    /// Interim in-app download so onboarding never sends anyone to Terminal.
    /// E1.3 replaces this with the real manager (resume, checksums, model picker).
    private func downloadSpeechModel() async {
        modelDownloadProgress = 0
        refresh()

        do {
            try await WhisperKitEngine.shared.prepare(
                allowDownload: true,
                progress: { [weak self] fraction in
                    Task { @MainActor in
                        self?.modelDownloadProgress = fraction
                        self?.refresh()
                    }
                }
            )
            modelDownloadProgress = nil
        } catch {
            modelDownloadProgress = nil
            let alert = NSAlert()
            alert.messageText = "Couldn’t download the speech model"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

private extension Array where Element == CheckItem {
    mutating func insert(_ item: CheckItem, afterID id: String) {
        guard let index = firstIndex(where: { $0.id == id }) else {
            append(item)
            return
        }
        insert(item, at: index + 1)
    }
}
