import Foundation
import Observation

/// Watches `CalendarService.upcoming` and:
///   - Arms the app 2 minutes before a qualifying event starts.
///   - Auto-starts recording at the event's start time.
///   - Tracks already-handled events so the same meeting never double-fires.
@MainActor
@Observable
final class AutoRecorder {
    private static let armWindow: TimeInterval = 120     // arm 2 min before
    private static let autoStartGrace: TimeInterval = 60 // start within 1 min of scheduled time
    private static let tickInterval: UInt64 = 15_000_000_000 // 15s

    var mode: AutoRecordMode {
        didSet { AutoRecordSettings.current = mode }
    }

    private(set) var armedEventId: String?

    private weak var appState: AppState?
    private var tickTask: Task<Void, Never>?
    private var startedEventIds: Set<String>
    private var armedShownIds: Set<String> = []

    init(appState: AppState) {
        self.appState = appState
        self.mode = AutoRecordSettings.current
        self.startedEventIds = AutoRecordSettings.startedEventIds
    }

    func start() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: Self.tickInterval)
            }
        }
    }

    func stop() {
        tickTask?.cancel()
        tickTask = nil
    }

    /// Called when a recording stops — clear armed state so we don't keep showing the badge.
    func recordingFinished() {
        armedEventId = nil
    }

    private func tick() async {
        guard mode != .off, let appState else { return }
        guard appState.status == .idle || appState.status == .armed else { return } // never override active recording

        let now = Date()
        guard let next = nextCandidate(now: now, events: appState.calendar.upcoming) else {
            // No qualifying upcoming event; un-arm if previously armed.
            if appState.status == .armed {
                appState.status = .idle
                armedEventId = nil
            }
            return
        }

        let secondsUntil = next.startDate.timeIntervalSince(now)

        // Window: T-armWindow .. T+autoStartGrace
        if secondsUntil <= 0 && secondsUntil >= -Self.autoStartGrace {
            if startedEventIds.contains(next.id) { return }
            rememberStarted(next.id)
            armedEventId = nil
            await appState.startRecording()
        } else if secondsUntil > 0 && secondsUntil <= Self.armWindow {
            if armedShownIds.contains(next.id) { return }
            armedShownIds.insert(next.id)
            armedEventId = next.id
            if appState.status == .idle {
                appState.status = .armed
            }
        }
    }

    private func nextCandidate(now: Date, events: [UpcomingEvent]) -> UpcomingEvent? {
        let cutoff = now.addingTimeInterval(Self.armWindow)
        return events
            .filter { mode.qualifies($0) }
            .filter { !startedEventIds.contains($0.id) }
            .filter { $0.startDate <= cutoff && $0.startDate.timeIntervalSince(now) >= -Self.autoStartGrace }
            .sorted { $0.startDate < $1.startDate }
            .first
    }

    /// Persist so a force-quit mid-recording cannot immediately re-fire the
    /// same calendar event on the next launch (in-memory set would be empty).
    private func rememberStarted(_ id: String) {
        startedEventIds.insert(id)
        AutoRecordSettings.startedEventIds = startedEventIds
    }
}
