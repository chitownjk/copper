import Foundation

/// Post-process model text so a long meeting cannot ship a looped quote or
/// leaked map-reduce scaffolding.
enum SummarySanitizer {
    private static let partHeading = try! NSRegularExpression(
        pattern: #"(?m)^#{1,6}\s*Part\s+\d+\s+of\s+\d+\s*$"#
    )
    private static let repeatedWord = try! NSRegularExpression(
        pattern: #"(\b[\w''-]+\b)(?:[ \t]+\1){2,}"#,
        options: [.caseInsensitive]
    )

    static func clean(_ text: String) -> String {
        var out = collapseRepeatedWords(text)
        out = stripPartHeadings(out)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func collapseRepeatedWords(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return repeatedWord.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: "$1"
        )
    }

    static func stripPartHeadings(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let stripped = partHeading.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: ""
        )
        return stripped
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
    }

    /// Two finished summaries glued together, or leftover "Part N of M".
    static func looksUnmerged(_ text: String) -> Bool {
        if partHeading.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
            return true
        }
        let tldr = text.ranges(of: "TL;DR", options: .caseInsensitive)
        return tldr.count >= 2
    }
}

private extension String {
    func ranges(of substring: String, options: String.CompareOptions = []) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var search = startIndex..<endIndex
        while let found = range(of: substring, options: options, range: search) {
            result.append(found)
            search = found.upperBound..<endIndex
        }
        return result
    }
}
