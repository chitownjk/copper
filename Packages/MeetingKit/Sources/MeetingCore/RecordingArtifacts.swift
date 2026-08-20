import AVFoundation
import Foundation

/// Filesystem facts about a recording directory, independent of the database.
///
/// Split out of `CrashRecovery` so the "what survived the crash?" question is
/// testable without standing up a database or an app (E1.5).
public enum RecordingArtifacts {
    public static let mixedFileName = "mixed.wav"
    public static let micFileName = "mic.wav"
    public static let systemFileName = "system.wav"
    public static let stemFileNames = [micFileName, systemFileName]

    /// Canonical RIFF/WAVE header. A file this size or smaller has no PCM.
    public static let wavHeaderByteCount = 44

    public static func mixedURL(in directory: URL) -> URL {
        directory.appendingPathComponent(mixedFileName)
    }

    public static func micURL(in directory: URL) -> URL {
        directory.appendingPathComponent(micFileName)
    }

    public static func systemURL(in directory: URL) -> URL {
        directory.appendingPathComponent(systemFileName)
    }

    /// Mix is the listen-back file. Verified means it exists, is larger than a
    /// WAV header, and AVAudioFile reports a duration — not merely that a
    /// `mixed.wav` name is sitting in the folder.
    public static func isMixVerified(in directory: URL) -> Bool {
        let url = mixedURL(in: directory)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > wavHeaderByteCount else { return false }
        guard let file = try? AVAudioFile(forReading: url) else { return false }
        let duration = Double(file.length) / file.processingFormat.sampleRate
        return duration > 0
    }

    /// Stems exist and have more than a header. Empty files count as missing
    /// so a leftover 44-byte stub does not force a rematch that would delete
    /// a good mix.
    public static func isUsableWAV(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return size > wavHeaderByteCount
    }

    public static func hasUsableStems(in directory: URL) -> Bool {
        stemFileNames.contains { name in
            isUsableWAV(directory.appendingPathComponent(name))
        }
    }

    /// After the mix checks out, mic.wav and system.wav are capture waste.
    /// Returns whether anything was actually deleted. Does nothing — and
    /// keeps the stems — when the mix is missing, empty, or unreadable.
    @discardableResult
    public static func dropStemsIfMixVerified(in directory: URL) -> Bool {
        guard isMixVerified(in: directory) else { return false }
        var deletedAnything = false
        for name in stemFileNames {
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                try FileManager.default.removeItem(at: url)
                deletedAnything = true
            } catch {
                print("Could not drop stem \(name): \(error)")
            }
        }
        return deletedAnything
    }

    /// Total bytes of captured audio. Zero means nothing was written before the
    /// process died, so there is nothing to recover. Counts every `.wav`,
    /// including leftover stems that have not been dropped yet.
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
