import Foundation
import MeetingCore
import Observation

/// Persisted Default / Record / Skip tags. Keyed by occurrence id and series id.
@MainActor
@Observable
final class CalendarTagStore {
    static let shared = CalendarTagStore()

    private static let key = "calendarEventTags"

    private(set) var tags: [CalendarEventTag]

    private init() {
        tags = Self.load()
    }

    func decision(for event: UpcomingEvent) -> CalendarRecordDecision? {
        CalendarRecordPolicy.taggedDecision(eventId: event.id, seriesId: event.seriesId, tags: tags)
    }

    func decision(for event: UpcomingEvent, grain: CalendarTagGrain) -> CalendarRecordDecision? {
        switch grain {
        case .thisTime:
            return tags.first(where: { $0.grain == .thisTime && $0.eventId == event.id })?.decision
        case .thisSeries:
            guard let seriesId = event.seriesId else { return nil }
            return tags.first(where: { $0.grain == .thisSeries && $0.seriesId == seriesId })?.decision
        }
    }

    func set(_ decision: CalendarRecordDecision?, grain: CalendarTagGrain, on event: UpcomingEvent) {
        tags.removeAll { tag in
            switch grain {
            case .thisTime:
                return tag.grain == .thisTime && tag.eventId == event.id
            case .thisSeries:
                return tag.grain == .thisSeries && tag.seriesId == event.seriesId
            }
        }
        if let decision {
            tags.append(CalendarEventTag(
                eventId: event.id,
                seriesId: event.seriesId,
                decision: decision,
                grain: grain
            ))
        }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(tags) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    private static func load() -> [CalendarEventTag] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([CalendarEventTag].self, from: data)
        else { return [] }
        return decoded
    }
}
