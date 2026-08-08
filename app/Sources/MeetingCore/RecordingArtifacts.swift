import Foundation

/// Filesystem facts about a recording directory, independent of the database.
///
/// Split out of `CrashRecovery` so the "what survived the crash?" question is
/// testable without standing up a database or an app (E1.5).
public enum RecordingArtifacts {
    /// Total bytes of captured audio. Zero means nothing was written before the
    /// process died, so there is nothing to recover.
    public static func audioBytes(in directory: URL) -> Int64 {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return 0
        }
        return names
            .filter { $0.hasSuffix(".wav") }
            .reduce(into: Int64(0)) { total, name in
                let size = try? directory.appendingPathComponent(name)
                    .resourceValues(forKeys: [.fileSizeKey]).fileSize
                total += Int64(size ?? 0)
            }
    }

    /// Best estimate of when recording actually stopped: the newest write to
    /// any file in the directory. Better than "now" — a crash may have happened
    /// hours before the user relaunched.
    public static func lastModified(in directory: URL) -> Date? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return nil
        }
        return names.compactMap { name in
            try? directory.appendingPathComponent(name)
                .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }.max()
    }

    public static func isRecoverable(directory: URL) -> Bool {
        audioBytes(in: directory) > 0
    }
}
