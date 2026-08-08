import Foundation

public enum Paths {
    /// Note: the directory name stays `MeetingNotes` until the brand pass (E3.5),
    /// which owns the rename plus its one-time migration.
    public static var applicationSupport: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let dir = base.appendingPathComponent("MeetingNotes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static var recordingsRoot: URL {
        let dir = applicationSupport.appendingPathComponent("recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Root of the Hugging Face-style cache WhisperKit downloads models into.
    public static var modelsRoot: URL {
        let dir = applicationSupport.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func makeRecordingDirectory(for id: String) throws -> URL {
        let dir = recordingsRoot.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
