import Foundation

/// Join engine segments into one paste-ready sentence. No partials, no
/// streaming — the spike pastes once after stop.
public enum DictationText {
    public static func join(_ segments: [TranscribedSegment]) -> String {
        let parts = segments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var text = parts.joined(separator: " ")
        while text.contains("  ") {
            text = text.replacingOccurrences(of: "  ", with: " ")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
