import Foundation

enum MeetingProvider: String {
    case zoom, googleMeet, teams, webex, other

    var label: String {
        switch self {
        case .zoom:       return "Zoom"
        case .googleMeet: return "Google Meet"
        case .teams:      return "Teams"
        case .webex:      return "Webex"
        case .other:      return "Link"
        }
    }
}

struct DetectedMeetingLink: Hashable {
    let url: URL
    let provider: MeetingProvider
}

enum MeetingURLDetector {
    /// Scans event title, location, notes, and structured URL field for a recognized meeting link.
    /// Returns the first match; ordering favors well-known providers.
    static func detect(in pieces: [String?]) -> DetectedMeetingLink? {
        let combined = pieces.compactMap { $0 }.joined(separator: "\n")
        guard !combined.isEmpty else { return nil }

        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        guard let detector else { return nil }

        let range = NSRange(combined.startIndex..<combined.endIndex, in: combined)
        let matches = detector.matches(in: combined, options: [], range: range)

        var best: DetectedMeetingLink?
        var bestRank = Int.max

        for match in matches {
            guard let url = match.url else { continue }
            let provider = classify(url)
            let rank = priority(provider)
            if rank < bestRank {
                best = DetectedMeetingLink(url: url, provider: provider)
                bestRank = rank
                if rank == 0 { break }
            }
        }
        return best
    }

    private static func classify(_ url: URL) -> MeetingProvider {
        let host = (url.host ?? "").lowercased()
        if host.contains("zoom.us") || host.contains("zoom.com") { return .zoom }
        if host.contains("meet.google.com") { return .googleMeet }
        if host.contains("teams.microsoft.com") || host.contains("teams.live.com") { return .teams }
        if host.contains("webex.com") { return .webex }
        return .other
    }

    private static func priority(_ provider: MeetingProvider) -> Int {
        switch provider {
        case .zoom:       return 0
        case .googleMeet: return 1
        case .teams:      return 2
        case .webex:      return 3
        case .other:      return 100
        }
    }
}
