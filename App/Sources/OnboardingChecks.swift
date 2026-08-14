import Foundation
import AppKit
import AVFoundation
import CoreGraphics
import EventKit
import MeetingCore
import MeetingProviders

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
}

enum CheckAction {
    case requestMic
    case openScreenRecordingSettings
    case requestCalendar
    case openInternetAccounts
    case openInstallInstructions(URL)
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
        items.allSatisfy { $0.status == .ok }
    }

    func refresh() {
        items = [
            micCheck(),
            screenRecordingCheck(),
            calendarCheck(),
            internetAccountsCheck(),
            modelCheck(),
            summarizerCheck()
        ]
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

    private func screenRecordingCheck() -> CheckItem {
        let granted = CGPreflightScreenCaptureAccess()
        return CheckItem(
            id: "screen",
            title: "Screen Recording (system audio)",
            detail: "Required to capture audio from Zoom/Meet/Teams. Toggled in System Settings → Privacy & Security → Screen Recording.",
            status: granted ? .ok : .denied,
            action: granted ? nil : .openScreenRecordingSettings
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
            action: cs == .ok ? nil : .requestCalendar
        )
    }

    /// Informational — always ready so it does not block the checklist.
    private func internetAccountsCheck() -> CheckItem {
        CheckItem(
            id: "internet-accounts",
            title: "Google or Outlook calendars",
            detail: "Add the account in System Settings → Internet Accounts. Companion then sees those events through Apple Calendar.",
            status: .ok,
            action: .openInternetAccounts
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
            action: nil
        )
    }

    private func modelCheck() -> CheckItem {
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
        case .openScreenRecordingSettings:
            CGRequestScreenCaptureAccess()
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        case .requestCalendar:
            await appState?.requestCalendarAccess()
        case .openInternetAccounts:
            InternetAccountsOpener.open()
        case .openInstallInstructions(let url):
            NSWorkspace.shared.open(url)
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
