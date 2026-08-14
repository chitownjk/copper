import AppKit
import EventKit
import MeetingCore
import SwiftUI

/// Today + 7 days. Per-event Default / Record / Skip. This time wins over series.
struct CalendarRecordListView: View {
    @Environment(AppState.self) private var appState
    @State private var grainByEvent: [String: CalendarTagGrain] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Calendar")
                .font(.title2.weight(.semibold))
            Text("Today and the next 7 days, from Apple Calendar. Default follows Settings. Record / Skip is daily work. This time beats this series.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        switch appState.calendar.access {
        case .denied:
            placeholder(
                title: "Calendar access denied",
                detail: "Enable Calendar in System Settings → Privacy & Security. Companion does not sign into Google."
            ) {
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        case .unknown, .unavailable:
            placeholder(
                title: "Connect Calendar",
                detail: "Companion reads Apple Calendar. Add Google or Outlook in System Settings → Internet Accounts — there is no Google sign-in in this app."
            ) {
                Button("Grant Calendar Access") {
                    Task { await appState.requestCalendarAccess() }
                }
                .buttonStyle(.borderedProminent)
                Button("Open Internet Accounts") {
                    InternetAccountsOpener.open()
                }
            }
        case .authorized:
            if appState.calendar.upcoming.isEmpty {
                placeholder(
                    title: "No events this week",
                    detail: "If you expected Google or Outlook events, add the account in System Settings → Internet Accounts, then refresh."
                ) {
                    Button("Refresh") {
                        Task { await appState.calendar.refresh(forceRemoteSync: true) }
                    }
                    Button("Open Internet Accounts") {
                        InternetAccountsOpener.open()
                    }
                }
            } else {
                eventList
            }
        }
    }

    private var eventList: some View {
        List {
            ForEach(grouped, id: \.day) { group in
                Section(group.label) {
                    ForEach(group.events) { event in
                        CalendarEventRow(
                            event: event,
                            grain: grainBinding(for: event),
                            mode: appState.autoRecorder.mode
                        )
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private var grouped: [(day: Date, label: String, events: [UpcomingEvent])] {
        let cal = Calendar.current
        let fmt = DateFormatter()
        fmt.dateStyle = .full
        let buckets = Dictionary(grouping: appState.calendar.upcoming) {
            cal.startOfDay(for: $0.startDate)
        }
        return buckets.keys.sorted().map { day in
            (day, fmt.string(from: day), buckets[day]!.sorted { $0.startDate < $1.startDate })
        }
    }

    private func grainBinding(for event: UpcomingEvent) -> Binding<CalendarTagGrain> {
        Binding(
            get: { grainByEvent[event.id] ?? .thisTime },
            set: { grainByEvent[event.id] = $0 }
        )
    }

    private func placeholder(title: String, detail: String, @ViewBuilder actions: () -> some View) -> some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.title3.weight(.semibold))
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            actions()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

private struct CalendarEventRow: View {
    let event: UpcomingEvent
    @Binding var grain: CalendarTagGrain
    let mode: AutoRecordMode
    private var store: CalendarTagStore { CalendarTagStore.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(timeRange)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 92, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(.system(size: 13, weight: .medium))
                    Text(meta)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack {
                Picker("Decision", selection: decisionBinding) {
                    Text("Default").tag(Optional<CalendarRecordDecision>.none)
                    Text("Record").tag(Optional.some(CalendarRecordDecision.record))
                    Text("Skip").tag(Optional.some(CalendarRecordDecision.skip))
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
                if event.isRecurring {
                    Picker("Grain", selection: $grain) {
                        ForEach(CalendarTagGrain.allCases) { g in
                            Text(g.label).tag(g)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 200)
                }
                Spacer()
            }
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .opacity(event.hasEnded ? 0.55 : 1)
    }

    private var decisionBinding: Binding<CalendarRecordDecision?> {
        Binding(
            get: { store.decision(for: event, grain: grain) },
            set: { store.set($0, grain: grain, on: event) }
        )
    }

    private var timeRange: String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return "\(f.string(from: event.startDate))–\(f.string(from: event.endDate))"
    }

    private var meta: String {
        var parts = [event.calendarTitle]
        if let link = event.meetingLink {
            parts.append(link.provider.label)
        } else {
            parts.append("In person")
        }
        if event.isRecurring { parts.append("Repeats") }
        return parts.joined(separator: " · ")
    }

    private var caption: String {
        let effective = store.decision(for: event)
        let hasLink = event.meetingLink != nil
        switch effective {
        case .skip:
            return "Will skip."
        case .record:
            return hasLink
                ? "Will record — microphone and system audio."
                : "Will record — microphone only (no meeting link)."
        case nil:
            if mode.qualifies(event) {
                return hasLink
                    ? "Default: meeting-link rule — will record mic + system."
                    : "Default: Settings rule — will record microphone only."
            }
            return "Default: Settings will not auto-record this event."
        }
    }
}

enum InternetAccountsOpener {
    /// Ventura+ Internet Accounts pane. Fall back to the path in copy if none open.
    static func open() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Accounts-Settings.extension",
            "x-apple.systempreferences:com.apple.settings.InternetAccounts",
            "x-apple.systempreferences:com.apple.preferences.internetaccounts"
        ]
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}
