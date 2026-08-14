import SwiftUI
import AppKit

struct MenuBarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if appState.dictation.isActive {
                dictationSection
                Divider()
            }

            recordingSection

            if let upcoming = upcomingLine {
                Divider()
                Text(upcoming)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Divider()

            if appState.camera.isLive {
                Button("Stop Virtual Camera") {
                    appState.camera.stopLive()
                }
            } else {
                Button("Go Live") {
                    Task { await appState.camera.goLive() }
                }
            }

            if !appState.recentMeetings.isEmpty {
                Divider()
                Text("Recent")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(appState.recentMeetings.prefix(3)) { row in
                    Button(row.title) {
                        appState.openMeeting(id: row.id)
                    }
                }
            }

            if let error = appState.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Divider()

            Button("Open Meeting Companion") {
                appState.mainWindow.show()
            }

            Button("Settings…") {
                appState.openSettings()
            }
            .keyboardShortcut(",")

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .tint(Brand.accent)
    }

    @ViewBuilder
    private var dictationSection: some View {
        switch appState.dictation.phase {
        case .listeningHold, .listeningHandsFree:
            Text("● Listening")
                .foregroundStyle(Brand.accent)
            Button("Stop Dictation") {
                appState.dictation.stopFromUI()
            }
        case .transcribing:
            Text("Transcribing…")
                .foregroundStyle(Brand.accent)
        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder
    private var recordingSection: some View {
        switch appState.status {
        case .idle:
            Button("Start Recording") {
                Task { await appState.startRecording() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("r")

        case .recording:
            Text("● Recording")
                .foregroundStyle(.red)
            Button("Stop Recording") {
                Task { await appState.stopRecording() }
            }
            .keyboardShortcut("r")

        case .armed:
            if let armed = armedEvent {
                Text("Armed: \(armed.title)")
                    .font(.callout)
            } else {
                Text("Armed for upcoming meeting")
                    .font(.callout)
            }
            Button("Start Now") {
                Task { await appState.startRecording() }
            }
            Button("Cancel Auto-Start") {
                appState.status = .idle
            }
        }
    }

    private var upcomingLine: String? {
        guard appState.calendar.access == .authorized,
              let event = appState.calendar.upcoming.first else { return nil }
        return "\(formatRelativeStart(event)) · \(event.title)"
    }

    private var armedEvent: UpcomingEvent? {
        guard let id = appState.autoRecorder.armedEventId else { return nil }
        return appState.calendar.upcoming.first { $0.id == id }
    }

    private func formatRelativeStart(_ event: UpcomingEvent) -> String {
        if event.isInProgress { return "Now" }
        let mins = event.minutesUntilStart
        if mins <= 0 { return "Starting" }
        if mins < 60 { return "In \(mins)m" }
        let hours = mins / 60
        let rem = mins % 60
        if rem == 0 { return "In \(hours)h" }
        return "In \(hours)h\(rem)m"
    }
}
