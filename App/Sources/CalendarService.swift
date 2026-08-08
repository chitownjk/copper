import Foundation
import EventKit

struct UpcomingEvent: Identifiable, Hashable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let calendarTitle: String
    let location: String?
    let meetingLink: DetectedMeetingLink?

    var isInProgress: Bool {
        let now = Date()
        return startDate <= now && now <= endDate
    }

    var minutesUntilStart: Int {
        Int(startDate.timeIntervalSinceNow / 60.0)
    }
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

    /// Fetches events from now to +24h across all calendars the user has authorized.
    /// Pass `forceRemoteSync: true` to nudge the local Calendar agent to pull from
    /// remote sources (Google/iCloud/Exchange) before reading.
    func refresh(forceRemoteSync: Bool = false) async {
        guard access == .authorized else { return }

        if forceRemoteSync {
            store.refreshSourcesIfNecessary()
            // Give the agent a beat to write new events into the local store.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }

        let now = Date()
        let end = now.addingTimeInterval(60 * 60 * 24)
        let calendars = store.calendars(for: .event)

        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-15 * 60), end: end, calendars: calendars)
        let events = store.events(matching: predicate)

        let mapped: [UpcomingEvent] = events
            .filter { !$0.isAllDay }
            .compactMap { ek -> UpcomingEvent? in
                guard let id = ek.eventIdentifier,
                      let start = ek.startDate,
                      let endDate = ek.endDate else { return nil }
                let link = MeetingURLDetector.detect(in: [
                    ek.title,
                    ek.location,
                    ek.notes,
                    ek.url?.absoluteString
                ])
                return UpcomingEvent(
                    id: id,
                    title: ek.title ?? "Untitled",
                    startDate: start,
                    endDate: endDate,
                    calendarTitle: ek.calendar?.title ?? "Calendar",
                    location: ek.location,
                    meetingLink: link
                )
            }
            .sorted { $0.startDate < $1.startDate }

        self.upcoming = mapped
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
