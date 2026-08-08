import Foundation

/// How long raw audio is kept after a meeting is transcribed (PRD A7).
///
/// Transcripts, notes, and summaries are never swept — they're small and they
/// are the product. This governs the WAV files only, which are ~85 MB/hour.
public enum RetentionPolicy: String, CaseIterable, Identifiable, Sendable {
    case forever
    case days30
    case afterTranscription

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .forever: return "Keep audio forever"
        case .days30: return "Delete audio after 30 days"
        case .afterTranscription: return "Delete audio once transcribed"
        }
    }

    public var detail: String {
        switch self {
        case .forever:
            return "Nothing is deleted automatically. Audio is roughly 85 MB per hour of meeting."
        case .days30:
            return "Transcripts, notes, and summaries are kept forever — only the audio files are removed."
        case .afterTranscription:
            return "Smallest footprint. You won't be able to re-transcribe or play back a meeting afterwards."
        }
    }

    /// Age past which audio is eligible for deletion, or `nil` if it never is.
    public var maximumAge: TimeInterval? {
        switch self {
        case .forever: return nil
        case .days30: return 30 * 24 * 60 * 60
        case .afterTranscription: return 0
        }
    }
}

public enum RetentionSettings {
    private static let policyKey = "retentionPolicy"
    private static let lastSweepKey = "retentionLastSweep"

    public static var policy: RetentionPolicy {
        get {
            UserDefaults.standard.string(forKey: policyKey)
                .flatMap(RetentionPolicy.init(rawValue:)) ?? .forever
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: policyKey) }
    }

    public static var lastSweep: Date? {
        get {
            let stamp = UserDefaults.standard.double(forKey: lastSweepKey)
            return stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
        }
        set { UserDefaults.standard.set(newValue?.timeIntervalSince1970 ?? 0, forKey: lastSweepKey) }
    }

    /// Sweeps run at most daily — this is housekeeping, not a hot path.
    public static func isSweepDue(now: Date = Date()) -> Bool {
        guard let lastSweep else { return true }
        return now.timeIntervalSince(lastSweep) >= 24 * 60 * 60
    }

    /// Whether a meeting's audio is eligible for deletion.
    ///
    /// - Parameters:
    ///   - endedAt: when the meeting finished.
    ///   - isPinned: the per-meeting "keep audio" override, which always wins.
    ///   - isProcessed: only fully-processed meetings are swept — deleting the
    ///     audio out from under a running pipeline would lose the transcript too.
    public static func shouldDeleteAudio(
        endedAt: Date,
        isPinned: Bool,
        isProcessed: Bool,
        policy: RetentionPolicy = RetentionSettings.policy,
        now: Date = Date()
    ) -> Bool {
        guard !isPinned, isProcessed else { return false }
        guard let maximumAge = policy.maximumAge else { return false }
        return now.timeIntervalSince(endedAt) >= maximumAge
    }
}
