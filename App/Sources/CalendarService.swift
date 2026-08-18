import Foundation
import EventKit
import MeetingCore

struct UpcomingEvent: Identifiable, Hashable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let calendarTitle: String
    let location: String?
    let meetingLink: DetectedMeetingLink?
    /// Non-nil when EventKit says this is a recurring series (or a detached occurrence).
    let seriesId: String?

    var isRecurring: Bool { seriesId != nil }

    var isInProgress: Bool {
        let now = Date()
        return startDate <= now && now <= endDate
    }

    var minutesUntilStart: Int {
        Int(startDate.timeIntervalSinceNow / 60.0)
    }

    var hasEnded: Bool { endDate < Date() }
}

@MainActor
@Observable
final class CalendarService {
    enum AccessState {
        case unknown
        case authorized
        case denied
        case unavailable // EventKit not present (rare)
    }

    var access: AccessState = .unknown
    var upcoming: [UpcomingEvent] = []
    var lastError: String?

    private let store = EKEventStore()
    private var refreshTask: Task<Void, Never>?

    init() {
        refreshAccessState()
    }

    func refreshAccessState() {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .fullAccess, .authorized, .writeOnly:
            access = .authorized
        case .denied, .restricted:
            access = .denied
        case .notDetermined:
            access = .unknown
        @unknown default:
            access = .unknown
        }
    }

    func requestAccess() async {
        do {
            let granted: Bool
            if #available(macOS 14, *) {
                granted = try await store.requestFullAccessToEvents()
            } else {
                granted = try await store.requestAccess(to: .event)
            }
            access = granted ? .authorized : .denied
            if granted { await refresh() }
        } catch {
            lastError = "Calendar access error: \(error.localizedDescription)"
            access = .denied
            ToastPresenter.shared.show(.error, title: "Calendar access denied", subtitle: error.localizedDescription)
        }
    }

    /// Today through seven days out, all EventKit calendars this Mac already has
    /// (iCloud / Google / Outlook via Internet Accounts — no OAuth here).
    func refresh(forceRemoteSync: Bool = false) async {
        guard access == .authorized else { return }

        if forceRemoteSync {
            store.refreshSourcesIfNecessary()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }

        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: 8, to: start) ?? Date().addingTimeInterval(8 * 24 * 3600)
        let calendars = store.calendars(for: .event)

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        let events = store.events(matching: predicate)

        let mapped: [UpcomingEvent] = events
            .compactMap { ek -> UpcomingEvent? in
                guard let id = ek.eventIdentifier, !id.isEmpty else { return nil }
                guard CalendarRecordPolicy.shouldDisplay(
                    title: ek.title,
                    start: ek.startDate,
                    end: ek.endDate,
                    isAllDay: ek.isAllDay
                ) else { return nil }
                guard let start = ek.startDate, let endDate = ek.endDate else { return nil }
                let link = MeetingURLDetector.detect(in: [
                    ek.title,
                    ek.location,
                    ek.notes,
                    ek.url?.absoluteString
                ])
                let recurring = ek.hasRecurrenceRules || ek.isDetached
                return UpcomingEvent(
                    id: id,
                    title: CalendarRecordPolicy.displayTitle(ek.title),
                    startDate: start,
                    endDate: endDate,
                    calendarTitle: ek.calendar?.title ?? "Calendar",
                    location: ek.location,
                    meetingLink: link,
                    seriesId: CalendarRecordPolicy.seriesId(fromEventIdentifier: id, hasRecurrence: recurring)
                )
            }
            .sorted { $0.startDate < $1.startDate }

        self.upcoming = mapped
    }

    /// Next in-progress or future event (menu extra).
    var nextUp: UpcomingEvent? {
        upcoming.first { !$0.hasEnded }
    }

    func startAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 60_000_000_000) // 60s
            }
        }
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }
}
