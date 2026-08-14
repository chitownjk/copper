import AppKit
import Foundation
import Observation
import GRDB
import MeetingCore

enum RecordingStatus {
    case idle
    case armed
    case recording
}

@MainActor
@Observable
final class AppState {
    var status: RecordingStatus = .idle
    var currentSession: RecordingSession?
    var recentMeetings: [MeetingRow] = []
    var lastError: String?

    let camera = CompanionCameraController()
    let dictation = DictationController()
    let cameraUse = CameraUseMonitor()
    @ObservationIgnored private(set) lazy var mainWindow = MainWindowController(appState: self)

    /// True when any client has "Meeting Companion Camera" open, including
    /// the extension's test-card fallback when we have not hit Go Live.
    var virtualCameraClaimed = false

    var pendingLibraryMeetingId: String?

    private var observationTask: Task<Void, Never>?
    private let notesPanel = NotesPanelController()
    @ObservationIgnored private var statusItem: StatusItemController?
    let calendar = CalendarService()
    private(set) var autoRecorder: AutoRecorder!
    private var onboarding: OnboardingWindowController!
    @ObservationIgnored private lazy var settings = SettingsWindowController(appState: self)

    init() {
        // Must run before anything reads a preference.
        LegacyDefaultsMigration.runIfNeeded()
        AppDelegate.onReopen = { [weak self] in self?.mainWindow.show() }
        startObservingMeetings()
        self.autoRecorder = AutoRecorder(appState: self)
        self.onboarding = OnboardingWindowController(appState: self)
        Task { await bootstrapCalendar() }
        if ProcessInfo.processInfo.arguments.contains("--recover-orphans") {
            Task {
                let result = await CrashRecovery.recoverAllHeadless()
                print("Recovered \(result.recovered) recording(s), skipped \(result.skipped).")
                NSApp.terminate(nil)
            }
        } else {
            Task { await CrashRecoveryPrompt.runIfNeeded() }
        }
        Task { await RetentionSweeper.sweepIfDue() }
        handleCameraExtensionFlags()
        handleCameraSinkPushFlag()
        handleCameraPassthroughFlag()
        // `--go-live`: start the persistent virtual-camera feed at launch and
        // keep running. Covers the case where the menu bar is too crowded to
        // reach our icon while a camera app is frontmost.
        if ProcessInfo.processInfo.arguments.contains("--go-live") {
            Task { @MainActor in
                await self.camera.goLive()
                if case .failed(let message) = self.camera.state {
                    print("go-live failed: \(message)")
                }
            }
        }
        // Dev affordance: this is a menu-bar app with no dock icon, so there's
        // otherwise no way to open a window straight from a launch.
        if let flag = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--settings") }) {
            let requested = flag.split(separator: "=").last.map(String.init) ?? ""
            let tab = SettingsTab(rawValue: requested) ?? .general
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                self.openSettings(tab: tab)
            }
        }
        showOnboardingIfFirstLaunch()
        subscribePipelineNotifications()
        statusItem = StatusItemController(appState: self)
        dictation.attach(
            isMeetingRecording: { [weak self] in self?.status == .recording },
            presentError: { [weak self] message in self?.setError(message) }
        )
        let headless = ProcessInfo.processInfo.arguments.contains {
            $0.hasPrefix("--recover-orphans")
                || $0.hasPrefix("--install-camera-extension")
                || $0.hasPrefix("--uninstall-camera-extension")
                || $0.hasPrefix("--push-camera-frames")
                || $0.hasPrefix("--camera-passthrough")
        }
        if !headless {
            cameraUse.attach(
                isRecording: { [weak self] in self?.status == .recording },
                weAreCapturing: { [weak self] in self?.camera.isLive == true },
                onYes: { [weak self] in
                    Task { await self?.startRecording(.cameraPrompt) }
                }
            )
        }
    }

    /// `--install-camera-extension` / `--uninstall-camera-extension`: headless
    /// E5.1 verification path, same spirit as `--recover-orphans`. Prints each
    /// state change; exits on a terminal one. "Needs approval" is not terminal
    /// — the OS finishes the request once the user approves in System
    /// Settings, so the process stays alive to see it.
    private func handleCameraExtensionFlags() {
        let arguments = ProcessInfo.processInfo.arguments
        let installing = arguments.contains("--install-camera-extension")
        let uninstalling = arguments.contains("--uninstall-camera-extension")
        guard installing || uninstalling else { return }

        let report: (CameraExtensionInstaller.Outcome) -> Void = { outcome in
            switch outcome {
            case .completed:
                print("camera extension: completed")
                NSApp.terminate(nil)
            case .willCompleteAfterReboot:
                print("camera extension: will complete after reboot")
                NSApp.terminate(nil)
            case .needsUserApproval:
                print("camera extension: needs approval — System Settings > General > Login Items & Extensions > Camera Extensions")
            case .failed(let error):
                let nsError = error as NSError
                print("camera extension: failed — \(nsError.domain) \(nsError.code): \(error.localizedDescription)")
                NSApp.terminate(nil)
            }
        }
        if installing {
            CameraExtensionInstaller.install(onOutcome: report)
        } else {
            CameraExtensionInstaller.uninstall(onOutcome: report)
        }
    }

    /// `--push-camera-frames[=seconds]`: connects to the extension's sink
    /// stream and pushes the app pattern at 30 fps, then exits. Headless
    /// verification for the E5.1 sink-transport step; default 10 s.
    private func handleCameraSinkPushFlag() {
        guard let flag = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--push-camera-frames") }) else { return }
        let seconds = flag.split(separator: "=").last.flatMap { Double($0) } ?? 10
        Task { @MainActor in
            do {
                let stats = try await CameraSinkPushProbe().run(seconds: seconds)
                print("camera sink: pushed \(stats.pushed) frame(s), dropped \(stats.dropped) over \(seconds)s")
            } catch {
                print("camera sink: failed — \(error.localizedDescription)")
            }
            NSApp.terminate(nil)
        }
    }

    /// `--camera-passthrough[=seconds]`: real camera → sink → virtual camera
    /// (the E5.2 tracer). Requires the camera TCC grant, so run it from a GUI
    /// launch with a user present. Default 30 s.
    private func handleCameraPassthroughFlag() {
        guard let flag = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--camera-passthrough") }) else { return }
        let seconds = flag.split(separator: "=").last.flatMap { Double($0) } ?? 30
        Task { @MainActor in
            do {
                let stats = try await CameraPassthroughProbe().run(seconds: seconds)
                print("camera passthrough: captured \(stats.captured), pushed \(stats.pushed), dropped \(stats.dropped) over \(seconds)s")
            } catch {
                print("camera passthrough: failed — \(error.localizedDescription)")
            }
            NSApp.terminate(nil)
        }
    }

    private func subscribePipelineNotifications() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: .pipelineDidComplete, object: nil, queue: .main) { note in
            let title = note.userInfo?["title"] as? String ?? "Meeting"
            Task { @MainActor in
                ToastPresenter.shared.show(.success, title: "Summary ready", subtitle: title)
            }
        }
        nc.addObserver(forName: .summarizationDidFail, object: nil, queue: .main) { note in
            let error = note.userInfo?["error"] as? String ?? "Unknown error"
            Task { @MainActor in
                ToastPresenter.shared.show(
                    .error,
                    title: "Summary failed — transcript saved",
                    subtitle: error
                )
            }
        }
        nc.addObserver(forName: .recordingDiskSpaceLow, object: nil, queue: .main) { note in
            let available = note.userInfo?["available"] as? String ?? "very little space"
            Task { @MainActor in
                ToastPresenter.shared.show(
                    .error,
                    title: "Running out of disk space",
                    subtitle: "\(available) left. Recording continues, but free up space now."
                )
            }
        }
        nc.addObserver(forName: .pipelineDidFail, object: nil, queue: .main) { note in
            let title = note.userInfo?["title"] as? String ?? "Meeting"
            let error = note.userInfo?["error"] as? String ?? "Unknown error"
            Task { @MainActor in
                ToastPresenter.shared.show(.error, title: "Processing failed: \(title)", subtitle: error)
            }
        }
    }

    func setError(_ message: String) {
        lastError = message
        ToastPresenter.shared.show(.error, title: "Error", subtitle: message)
    }

    private static let didFirstLaunchKey = "didCompleteFirstLaunch"

    private func showOnboardingIfFirstLaunch() {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: Self.didFirstLaunchKey) {
            defaults.set(true, forKey: Self.didFirstLaunchKey)
            // Defer to next runloop so the menu bar exists first.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 200_000_000)
                self.openOnboarding()
            }
        }
    }

    func openOnboarding() {
        onboarding.show()
    }

    func openSettings(tab: SettingsTab = .general) {
        settings.show(tab: tab)
    }

    private func bootstrapCalendar() async {
        calendar.refreshAccessState()
        if calendar.access == .authorized {
            await calendar.refresh()
            calendar.startAutoRefresh()
            autoRecorder.start()
        }
    }

    func requestCalendarAccess() async {
        await calendar.requestAccess()
        if calendar.access == .authorized {
            calendar.startAutoRefresh()
            autoRecorder.start()
        }
    }

    var menuBarSymbol: String {
        switch status {
        case .idle:      return "waveform"
        case .armed:     return "waveform.badge.exclamationmark"
        case .recording: return "record.circle.fill"
        }
    }

    func startRecording(_ request: RecordingRequest = .manual) async {
        guard status == .idle || status == .armed else { return }
        if ScreenLock.isLocked {
            setError("Unlock this Mac to start recording.")
            return
        }
        do {
            let session = try await RecordingSession.start(request)
            currentSession = session
            status = .recording
            lastError = nil
            notesPanel.show(
                meetingId: session.meeting.id,
                recordingStart: session.meeting.startedAt
            )
            let subtitle: String?
            switch request.capture {
            case .micAndSystem: subtitle = request.title
            case .micOnly: subtitle = "Microphone only"
            }
            ToastPresenter.shared.show(.info, title: "Recording started", subtitle: subtitle)
        } catch {
            setError("Start failed: \(error.localizedDescription)")
            status = .idle
        }
    }

    func openLibrary() {
        mainWindow.show()
    }

    func openMeeting(id: String) {
        pendingLibraryMeetingId = id
        mainWindow.show()
    }

    func stopRecording() async {
        guard let session = currentSession else { return }
        let meetingId = session.meeting.id

        await notesPanel.hide()

        do {
            try await session.stop()
            ToastPresenter.shared.show(.info, title: "Recording stopped", subtitle: "Processing in background…")
        } catch {
            setError("Stop failed: \(error.localizedDescription)")
        }
        currentSession = nil
        status = .idle
        autoRecorder.recordingFinished()

        Task.detached(priority: .utility) {
            await Pipeline.shared.process(meetingId: meetingId)
        }
    }

    private func startObservingMeetings() {
        let observation = ValueObservation.tracking { db in
            try MeetingRow
                .order(Column("started_at").desc)
                .limit(20)
                .fetchAll(db)
        }
        observationTask = Task { [weak self] in
            do {
                for try await meetings in observation.values(in: Database.shared) {
                    await MainActor.run {
                        self?.recentMeetings = meetings
                    }
                }
            } catch {
                print("Meeting observation error: \(error)")
            }
        }
    }
}
