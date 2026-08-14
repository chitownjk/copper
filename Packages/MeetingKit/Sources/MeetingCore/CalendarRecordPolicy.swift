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
}
