import Foundation

enum AutoRecordMode: String, CaseIterable, Identifiable {
    case off
    case flag      // only events with [record] in title
    case detected  // events with a Zoom/Meet/Teams/Webex link
    case all       // every calendar event

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off:      return "Off"
        case .flag:     return "When title contains [record]"
        case .detected: return "Events with a meeting link"
        case .all:      return "All calendar events"
        }
    }

    /// Decides whether this event qualifies for auto-record under this mode.
    func qualifies(_ event: UpcomingEvent) -> Bool {
        switch self {
        case .off:
            return false
        case .flag:
            return event.title.lowercased().contains("[record]")
        case .detected:
            return event.meetingLink != nil
        case .all:
            return true
        }
    }
}

enum AutoRecordSettings {
    private static let key = "autoRecordMode"

    static var current: AutoRecordMode {
        get {
            let raw = UserDefaults.standard.string(forKey: key) ?? AutoRecordMode.flag.rawValue
            return AutoRecordMode(rawValue: raw) ?? .flag
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
        }
    }
}
