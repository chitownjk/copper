import AppKit
import AVFoundation
import Foundation
import MeetingCore
import Observation

/// Local-first Wispr-style dictation. Isolated from the meeting library,
/// calendar, dual-stream mix, and CompanionVideoCore.
@MainActor
@Observable
final class DictationController {
    enum Phase: Equatable {
        case idle
        case listeningHold
        case listeningHandsFree
        case transcribing
    }

    private(set) var phase: Phase = .idle

    var isActive: Bool { phase != .idle }

    @ObservationIgnored private let hotkey = DictationHotkeyMonitor()
    @ObservationIgnored private let hud = DictationHUDController()
    @ObservationIgnored private var capture: MicRecorder?
    @ObservationIgnored private var captureURL: URL?
    @ObservationIgnored private var transcribeTask: Task<Void, Never>?
    @ObservationIgnored private var sessionID = UUID()
    @ObservationIgnored private var isMeetingRecording: () -> Bool = { false }
    @ObservationIgnored private var presentError: (String) -> Void = { _ in }

    func attach(isMeetingRecording: @escaping () -> Bool, presentError: @escaping (String) -> Void) {
        self.isMeetingRecording = isMeetingRecording
        self.presentError = presentError
        guard !Self.isHeadlessLaunch else { return }
        hud.onStop = { [weak self] in
            self?.stopFromUI()
        }
        hotkey.onAction = { [weak self] action in
            self?.handle(action)
        }
        hotkey.start()
    }

    func stopFromUI() {
        hotkey.resetMachine()
        Task { await stopAndCommit() }
    }

    // MARK: - Gesture actions

    private func handle(_ action: DictationGestureMachine.Action) {
        switch action {
        case .none:
            break
        case .startHold:
            Task { await start(kind: .hold) }
        case .startHandsFree:
            Task { await start(kind: .handsFree) }
        case .stop:
            Task { await stopAndCommit() }
        case .cancel:
            cancel()
        }
    }

    private enum Kind {
        case hold
        case handsFree
    }

    private func start(kind: Kind) async {
        if capture != nil || phase == .transcribing {
            return
        }
        let id = UUID()
        sessionID = id
        if isMeetingRecording() {
            failAndReset("Stop the meeting recording before dictating.")
            return
        }
        if DictationPermissions.isSecureEventInputEnabled() {
            failAndReset("Secure Keyboard Entry is on. Turn it off to dictate.")
            return
        }
        if !DictationPermissions.isAccessibilityTrusted() {
            DictationPermissions.promptAccessibility()
            failAndReset("Grant Accessibility, then hold \(DictationHotkeySettings.current.displayName) to dictate.")
            return
        }
        switch DictationPermissions.microphoneStatus() {
        case .authorized:
            break
        case .denied, .restricted:
            failAndReset("Microphone access is denied in System Settings.")
            return
        case .notDetermined:
            let granted = await DictationPermissions.requestMicrophone()
            hotkey.resetMachine()
            if granted {
                presentError("Microphone is ready. Hold \(DictationHotkeySettings.current.displayName) to dictate.")
            } else {
                presentError("Microphone access is required to dictate.")
            }
            return
        @unknown default:
            failAndReset("Microphone access is required to dictate.")
            return
        }
        if DictationInserter.focusedFieldIsSecure() {
            failAndReset("Can't dictate into a password field.")
            return
        }

        let engine = TranscriptionEngines.current()
        if await !engine.isReady() {
            failAndReset("Speech model isn’t ready. Download it in Settings → Transcription.")
            return
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictation-\(UUID().uuidString).wav")
        do {
            guard sessionID == id, capture == nil, phase == .idle else { return }
            let recorder = try MicRecorder(outputURL: url)
            try recorder.start()
            guard sessionID == id else {
                recorder.stop()
                try? FileManager.default.removeItem(at: url)
                return
            }
            capture = recorder
            captureURL = url
            phase = kind == .hold ? .listeningHold : .listeningHandsFree
            hud.show(.listening(handsFree: kind == .handsFree))
        } catch {
            try? FileManager.default.removeItem(at: url)
            failAndReset("Couldn’t start the microphone: \(error.localizedDescription)")
        }
    }

    private func stopAndCommit() async {
        sessionID = UUID()
        guard capture != nil, let url = captureURL else {
            phase = .idle
            hud.hide()
            return
        }
        capture?.stop()
        capture = nil
        captureURL = nil
        phase = .transcribing
        hud.show(.transcribing)

        transcribeTask?.cancel()
        transcribeTask = Task { [weak self] in
            await self?.transcribeAndInsert(url: url)
        }
        await transcribeTask?.value
    }

    private func transcribeAndInsert(url: URL) async {
        defer {
            try? FileManager.default.removeItem(at: url)
        }
        do {
            let engine = TranscriptionEngines.current()
            let segments = try await engine.transcribe(
                audioURL: url,
                language: TranscriptionSettings.language,
                progress: nil
            )
            if Task.isCancelled {
                finishIdle()
                return
            }
            let text = DictationText.join(segments)
            guard !text.isEmpty else {
                failAndReset("Didn’t catch that. Try again.")
                return
            }
            switch await DictationInserter.insert(text) {
            case .insertedViaAX:
                finishWithNote(.inserted("Inserted via AX"))
            case .pasted:
                finishWithNote(.inserted("Pasted"))
            case .copiedInstead:
                finishWithNote(.copied("Automatic insert failed. Press ⌘V."))
                ToastPresenter.shared.show(
                    .info,
                    title: "Copied — press ⌘V",
                    subtitle: "This app blocked automatic insert. The sentence is on the clipboard."
                )
            case .blocked(let message):
                failAndReset(message)
            }
        } catch {
            failAndReset(error.localizedDescription)
        }
    }

    private func cancel() {
        sessionID = UUID()
        transcribeTask?.cancel()
        transcribeTask = nil
        capture?.stop()
        if let url = captureURL {
            try? FileManager.default.removeItem(at: url)
        }
        capture = nil
        captureURL = nil
        finishIdle()
    }

    private func failAndReset(_ message: String) {
        sessionID = UUID()
        hotkey.resetMachine()
        capture?.stop()
        if let url = captureURL {
            try? FileManager.default.removeItem(at: url)
        }
        capture = nil
        captureURL = nil
        transcribeTask?.cancel()
        transcribeTask = nil
        phase = .idle
        hud.show(.blocked(message))
        presentError(message)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1600))
            if self?.phase == .idle {
                self?.hud.hide()
            }
        }
    }

    private func finishIdle() {
        phase = .idle
        hud.hide()
    }

    private func finishWithNote(_ phase: DictationHUDPhase) {
        self.phase = .idle
        hud.show(phase)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1600))
            if self?.phase == .idle {
                self?.hud.hide()
            }
        }
    }

    private static var isHeadlessLaunch: Bool {
        ProcessInfo.processInfo.arguments.contains {
            $0.hasPrefix("--recover-orphans")
                || $0.hasPrefix("--install-camera-extension")
                || $0.hasPrefix("--uninstall-camera-extension")
                || $0.hasPrefix("--push-camera-frames")
                || $0.hasPrefix("--camera-passthrough")
        }
    }
}
