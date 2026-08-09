import SwiftUI
import AppKit
import MeetingCore
import CompanionVideoCore
import UniformTypeIdentifiers

struct MenuBarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            switch appState.status {
            case .idle:
                Button("Start Recording") {
                    Task { await appState.startRecording() }
                }
                .keyboardShortcut("r")

            case .recording:
                Text("● Recording")
                Button("Stop Recording") {
                    Task { await appState.stopRecording() }
                }
                .keyboardShortcut("r")

            case .armed:
                if let armed = armedEvent {
                    Text("Armed: \(armed.title)")
                        .font(.caption)
                } else {
                    Text("Armed for upcoming meeting")
                }
                Button("Start Now") {
                    Task { await appState.startRecording() }
                }
                Button("Cancel Auto-Start") {
                    appState.status = .idle
                }
            }

            Divider()

            cameraSection

            Divider()

            calendarSection

            if !appState.recentMeetings.isEmpty {
                Text("Recent")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(appState.recentMeetings.prefix(5)) { row in
                    Button("\(row.title) — \(statusLabel(row.statusEnum))") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: row.audioDir))
                    }
                }
                Divider()
            }

            if let error = appState.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button("Reveal Recordings in Finder") {
                NSWorkspace.shared.open(Paths.recordingsRoot)
            }

            Button("Open Library") {
                appState.openLibrary()
            }
            .keyboardShortcut("l")

            Button("Settings…") {
                appState.openSettings()
            }
            .keyboardShortcut(",")

            Button("Setup…") {
                appState.openOnboarding()
            }

            Menu("Auto-Record: \(appState.autoRecorder.mode.label)") {
                ForEach(AutoRecordMode.allCases) { mode in
                    Button {
                        appState.autoRecorder.mode = mode
                    } label: {
                        if mode == appState.autoRecorder.mode {
                            Label(mode.label, systemImage: "checkmark")
                        } else {
                            Text(mode.label)
                        }
                    }
                }
            }

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }

    /// Video companion controls (E5.2). "Go Live" feeds the virtual camera;
    /// the logo is baked into our outgoing frames, so it persists regardless
    /// of downstream filters/backgrounds (macOS effects, Meet, Zoom).
    @ViewBuilder
    private var cameraSection: some View {
        switch appState.camera.state {
        case .live:
            Text("● Camera Live")
            Button("Stop Virtual Camera") {
                appState.camera.stopLive()
            }
        case .off:
            Button("Go Live (Virtual Camera)") {
                Task { await appState.camera.goLive() }
            }
        case .failed(let message):
            Button("Go Live (Virtual Camera)") {
                Task { await appState.camera.goLive() }
            }
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
        }

        Picker("Background", selection: Binding(
            get: { appState.camera.backgroundMode },
            set: { appState.camera.setBackgroundMode($0) }
        )) {
            Text("None").tag(BackgroundMode.none)
            Text("Blur").tag(BackgroundMode.blur)
        }

        if appState.camera.backgroundMode == .blur {
            Picker("Blur Strength", selection: Binding(
                get: { appState.camera.blurStrength },
                set: { appState.camera.setBlurStrength($0) }
            )) {
                ForEach(BlurStrength.allCases, id: \.self) { strength in
                    Text(strength.label).tag(strength)
                }
            }
        }

        if appState.camera.logoURL == nil {
            Button("Add Camera Logo…") { chooseLogo() }
        } else {
            Menu("Camera Logo: \(appState.camera.logoURL?.lastPathComponent ?? "")") {
                Button("Change Logo…") { chooseLogo() }
                Picker("Size", selection: Binding(
                    get: { appState.camera.logoSize },
                    set: { appState.camera.setLogoSize($0) }
                )) {
                    ForEach(CompanionCameraController.LogoSize.allCases, id: \.self) { size in
                        Text(size.label).tag(size)
                    }
                }
                Button("Remove Logo") { appState.camera.setLogo(url: nil) }
            }
        }

        // Off by default: meeting apps mirror only your local self-view, so
        // remote participants already see everything the right way round.
        // This flips what THEY see too.
        Toggle("Mirror Output (flips for viewers too)", isOn: Binding(
            get: { appState.camera.mirrorsOutput },
            set: { appState.camera.setMirrorOutput($0) }
        ))
    }

    private func chooseLogo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .tiff, .heic, .jpeg]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a logo image (PNG with transparency works best)."
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            appState.camera.setLogo(url: url)
        }
    }

    @ViewBuilder
    private var calendarSection: some View {
        switch appState.calendar.access {
        case .unknown:
            Button("Connect Calendar…") {
                Task { await appState.requestCalendarAccess() }
            }
            Divider()

        case .denied:
            Text("Calendar access denied")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Open System Settings") {
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!
                NSWorkspace.shared.open(url)
            }
            Divider()

        case .unavailable:
            EmptyView()

        case .authorized:
            let upcoming = appState.calendar.upcoming.prefix(4)
            if upcoming.isEmpty {
                Text("No upcoming meetings")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Upcoming")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(Array(upcoming), id: \.id) { event in
                    upcomingRow(event)
                }
            }
            Button("Refresh Calendar") {
                Task { await appState.calendar.refresh(forceRemoteSync: true) }
            }
            .keyboardShortcut("k")
            Divider()
        }
    }

    @ViewBuilder
    private func upcomingRow(_ event: UpcomingEvent) -> some View {
        let timeLabel = formatRelativeStart(event)
        let primary = "\(timeLabel) · \(event.title)"
        let providerSuffix = event.meetingLink.map { " — \($0.provider.label)" } ?? ""

        if let link = event.meetingLink {
            Menu("\(primary)\(providerSuffix)") {
                Button("Open \(link.provider.label)") {
                    NSWorkspace.shared.open(link.url)
                }
                Button("Start Recording") {
                    Task { await appState.startRecording() }
                }
                Button("Open & Record") {
                    NSWorkspace.shared.open(link.url)
                    Task { await appState.startRecording() }
                }
            }
        } else {
            Button(primary) {
                Task { await appState.startRecording() }
            }
        }
    }

    private func formatRelativeStart(_ event: UpcomingEvent) -> String {
        if event.isInProgress { return "● now" }
        let mins = event.minutesUntilStart
        if mins <= 0 { return "starting" }
        if mins < 60 { return "in \(mins)m" }
        let hours = mins / 60
        let rem = mins % 60
        if rem == 0 { return "in \(hours)h" }
        return "in \(hours)h\(rem)m"
    }

    private var armedEvent: UpcomingEvent? {
        guard let id = appState.autoRecorder.armedEventId else { return nil }
        return appState.calendar.upcoming.first { $0.id == id }
    }

    private func statusLabel(_ status: MeetingStatus) -> String {
        switch status {
        case .recording:    return "● rec"
        case .mixing:       return "mixing…"
        case .transcribing: return "transcribing…"
        case .summarizing:  return "summarizing…"
        case .ready:        return "ready"
        case .failed:       return "failed"
        }
    }
}
