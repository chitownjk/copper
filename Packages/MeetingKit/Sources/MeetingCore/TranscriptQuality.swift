import Foundation

/// Whisper (and similar ASR) invents caption-track junk on short or quiet
/// takes — "thank you" at 0s is the classic. A one-sentence recording must
/// not become a fictional meeting summary.
public enum TranscriptQuality {
    /// Normalized phrases that are almost never real meeting content when
    /// they are the entire transcript.
    public static let knownHallucinations: Set<String> = [
        "thank you",
        "thanks",
        "thanks for watching",
        "thank you for watching",
        "thanks for listening",
        "thank you for listening",
        "please subscribe",
        "subscribe",
        "subtitle",
        "subtitles",
        "you",
        "bye",
        "goodbye",
        "thanks for watching please subscribe",
    ]

    public static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let stripped = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == " " {
                return Character(scalar)
            }
            return " "
        }
        return String(stripped)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    public static func isHallucination(_ text: String) -> Bool {
        let n = normalize(text)
        return n.isEmpty || knownHallucinations.contains(n)
    }

    public static func filter(_ segments: [TranscribedSegment]) -> [TranscribedSegment] {
        segments.filter { !isHallucination($0.text) }
    }

    /// A transcript is usable when something remains after dropping known
    /// hallucinations. A few-second take whose only leftover is a couple of
    /// words is also rejected — there is nothing honest to summarize.
    public static func isUsable(
        segments: [TranscribedSegment],
        recordingDurationSeconds: TimeInterval?
    ) -> Bool {
        let kept = filter(segments)
        let text = kept
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if text.isEmpty { return false }
        if let duration = recordingDurationSeconds, duration < 8, text.count < 24 {
            return false
        }
        return true
    }
}
