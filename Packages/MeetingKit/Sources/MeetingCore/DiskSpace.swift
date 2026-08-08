import Foundation

/// Free-space checks around recording (E1.5).
///
/// Dual 48 kHz Float32 tracks cost roughly 1.4 MB per minute; a long meeting
/// plus its mixdown and the transcription model's scratch space is the reason
/// the floor is measured in gigabytes rather than megabytes.
public enum DiskSpace {
    public static let requiredToStartBytes: Int64 = 2 * 1_024 * 1_024 * 1_024
    public static let warnDuringRecordingBytes: Int64 = 1_024 * 1_024 * 1_024

    /// Space available to this app on the volume holding `url`, or `nil` if the
    /// volume can't be queried (in which case callers should not block).
    public static func availableBytes(at url: URL = Paths.applicationSupport) -> Int64? {
        guard let values = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ) else { return nil }
        return values.volumeAvailableCapacityForImportantUsage
    }

    public static func canStartRecording(at url: URL = Paths.applicationSupport) -> Bool {
        guard let available = availableBytes(at: url) else { return true }
        return available >= requiredToStartBytes
    }

    public static func isLowDuringRecording(at url: URL = Paths.applicationSupport) -> Bool {
        guard let available = availableBytes(at: url) else { return false }
        return available < warnDuringRecordingBytes
    }

    public static func describe(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

public enum DiskSpaceError: Error, LocalizedError {
    case insufficientToStart(available: Int64)

    public var errorDescription: String? {
        switch self {
        case .insufficientToStart(let available):
            return "Only \(DiskSpace.describe(available)) free — recording needs at least "
                + "\(DiskSpace.describe(DiskSpace.requiredToStartBytes)). Free up space and try again."
        }
    }
}
