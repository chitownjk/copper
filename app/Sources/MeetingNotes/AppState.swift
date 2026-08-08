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

    private var observationTask: Task<Void, Never>?
    private let notesPanel = NotesPanelController()
    private let library = LibraryWindowController()
    let calendar = CalendarService()
    private(set) var autoRecorder: AutoRecorder!
    private var onboarding: OnboardingWindowController!

    init() {
        startObservingMeetings()
        self.autoRecorder = AutoRecorder(appState: self)
        self.onboarding = OnboardingWindowController(appState: self)
        Task { await bootstrapCalendar() }
        Task { await CrashRecoveryPrompt.runIfNeeded() }
        showOnboardingIfFirstLaunch()
        subscribePipelineNotifications()
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

    func startRecording() async {
        guard status == .idle || status == .armed else { return }
        do {
            let session = try await RecordingSession.start()
            currentSession = session
            status = .recording
            lastError = nil
            notesPanel.show(
                meetingId: session.meeting.id,
                recordingStart: session.meeting.startedAt
            )
            ToastPresenter.shared.show(.info, title: "Recording started", subtitle: nil)
        } catch {
            setError("Start failed: \(error.localizedDescription)")
            status = .idle
        }
    }

    func openLibrary() {
        library.show()
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
