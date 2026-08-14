import Foundation
import MeetingCore

enum MeetingProvider: String {
    case zoom, googleMeet, teams, webex

    init(_ kind: MeetingURLKind) {
        switch kind {
        case .zoom:       self = .zoom
        case .googleMeet: self = .googleMeet
        case .teams:      self = .teams
        case .webex:      self = .webex
        }
    }

    var label: String {
        switch self {
        case .zoom:       return "Zoom"
        case .googleMeet: return "Google Meet"
        case .teams:      return "Teams"
        case .webex:      return "Webex"
        }
    }
}

struct DetectedMeetingLink: Hashable {
    let url: URL
    let provider: MeetingProvider
}

enum MeetingURLDetector {
    /// Scans event title, location, notes, and structured URL field for a
    /// recognized meeting link. Drive / Docs / Calendar / random https are
    /// not meeting links — `detect` returns nil for those.
    static func detect(in pieces: [String?]) -> DetectedMeetingLink? {
        guard let hit = MeetingURLClassifier.detect(in: pieces) else { return nil }
        return DetectedMeetingLink(url: hit.url, provider: MeetingProvider(hit.kind))
    }
}
