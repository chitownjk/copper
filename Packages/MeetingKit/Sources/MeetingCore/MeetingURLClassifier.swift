import Foundation

/// Hosts that count as a real meeting link. Drive, Docs, Calendar, and
/// any other https URL are not meetings — auto-record "events with a
/// meeting link" must not fire on those.
public enum MeetingURLKind: String, Sendable, Equatable {
    case zoom, googleMeet, teams, webex
}

public struct ClassifiedMeetingURL: Equatable, Sendable {
    public let url: URL
    public let kind: MeetingURLKind
}

public enum MeetingURLClassifier {
    /// Classifies a single URL. Returns `nil` unless the host is Zoom,
    /// Google Meet, Teams, or Webex.
    public static func classify(_ url: URL) -> MeetingURLKind? {
        let host = (url.host ?? "").lowercased()
        if hostMatches(host, suffix: "zoom.us") || hostMatches(host, suffix: "zoom.com") {
            return .zoom
        }
        if hostMatches(host, suffix: "meet.google.com") {
            return .googleMeet
        }
        if hostMatches(host, suffix: "teams.microsoft.com") || hostMatches(host, suffix: "teams.live.com") {
            return .teams
        }
        if hostMatches(host, suffix: "webex.com") {
            return .webex
        }
        return nil
    }

    /// First recognized meeting link in the joined text. Drive / Docs /
    /// Calendar / random https are ignored, not returned as "other".
    public static func detect(in pieces: [String?]) -> ClassifiedMeetingURL? {
        let combined = pieces.compactMap { $0 }.joined(separator: "\n")
        guard !combined.isEmpty else { return nil }

        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        guard let detector else { return nil }

        let range = NSRange(combined.startIndex..<combined.endIndex, in: combined)
        let matches = detector.matches(in: combined, options: [], range: range)

        var best: ClassifiedMeetingURL?
        var bestRank = Int.max

        for match in matches {
            guard let url = match.url, let kind = classify(url) else { continue }
            let rank = priority(kind)
            if rank < bestRank {
                best = ClassifiedMeetingURL(url: url, kind: kind)
                bestRank = rank
                if rank == 0 { break }
            }
        }
        return best
    }

    private static func hostMatches(_ host: String, suffix: String) -> Bool {
        host == suffix || host.hasSuffix("." + suffix)
    }

    private static func priority(_ kind: MeetingURLKind) -> Int {
        switch kind {
        case .zoom:       return 0
        case .googleMeet: return 1
        case .teams:      return 2
        case .webex:      return 3
        }
    }
}
