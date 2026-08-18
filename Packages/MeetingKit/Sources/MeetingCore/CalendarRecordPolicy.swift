import Foundation

public enum CalendarRecordDecision: String, Sendable, Codable, CaseIterable, Identifiable {
    case record
    case skip

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .record: return "Record"
        case .skip:   return "Skip"
        }
    }
}

public enum CalendarTagGrain: String, Sendable, Codable, CaseIterable, Identifiable {
    case thisTime
    case thisSeries

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .thisTime:   return "This time"
        case .thisSeries: return "This series"
        }
    }
}

public struct CalendarEventTag: Sendable, Codable, Equatable, Identifiable {
    public var eventId: String
    public var seriesId: String?
    public var decision: CalendarRecordDecision
    public var grain: CalendarTagGrain

    public init(eventId: String, seriesId: String?, decision: CalendarRecordDecision, grain: CalendarTagGrain) {
        self.eventId = eventId
        self.seriesId = seriesId
        self.decision = decision
        self.grain = grain
    }

    public var id: String {
        switch grain {
        case .thisTime:   return "occ:\(eventId)"
        case .thisSeries: return "series:\(seriesId ?? eventId)"
        }
    }
}

/// Per-event tags on top of the Settings auto-record rule.
/// This-time always wins over this-series. Absence means Default.
public enum CalendarRecordPolicy {
    public static func taggedDecision(
        eventId: String,
        seriesId: String?,
        tags: [CalendarEventTag]
    ) -> CalendarRecordDecision? {
        if let occ = tags.first(where: { $0.grain == .thisTime && $0.eventId == eventId }) {
            return occ.decision
        }
        if let seriesId,
           let series = tags.first(where: { $0.grain == .thisSeries && $0.seriesId == seriesId }) {
            return series.decision
        }
        return nil
    }

    /// Meeting-link events capture mic + system. In-person (no Zoom/Meet/Teams/Webex link) is mic only.
    public static func includesSystemAudio(hasMeetingLink: Bool) -> Bool {
        hasMeetingLink
    }

    /// Recurring EventKit occurrence ids look like `baseID/yyyyMMddTHHmmssZ`.
    public static func seriesId(fromEventIdentifier identifier: String?, hasRecurrence: Bool) -> String? {
        guard hasRecurrence, let identifier, !identifier.isEmpty else { return nil }
        if let slash = identifier.firstIndex(of: "/") {
            let base = String(identifier[..<slash])
            return base.isEmpty ? identifier : base
        }
        return identifier
    }

    /// Empty / whitespace EventKit titles become a visible fallback so a row is never just pickers.
    public static func displayTitle(_ raw: String?) -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled event" : trimmed
    }

    /// Keep timed EventKit events. Drop all-day, missing dates, and untitled midnight-spanning leftovers
    /// that EventKit sometimes fails to mark `isAllDay` (empty-title rhythm / holiday blocks).
    public static func shouldDisplay(
        title: String?,
        start: Date?,
        end: Date?,
        isAllDay: Bool,
        calendar: Calendar = .current
    ) -> Bool {
        if isAllDay { return false }
        guard let start, let end, end > start else { return false }
        let usableTitle = !(title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if usableTitle { return true }
        return !looksLikeAllDayLeftover(start: start, end: end, calendar: calendar)
    }

    public static func looksLikeAllDayLeftover(
        start: Date,
        end: Date,
        calendar: Calendar = .current
    ) -> Bool {
        let parts = calendar.dateComponents([.hour, .minute, .second], from: start)
        let midnight = (parts.hour ?? 0) == 0 && (parts.minute ?? 0) == 0 && (parts.second ?? 0) == 0
        return midnight && end.timeIntervalSince(start) >= 20 * 3600
    }
}
