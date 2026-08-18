import Foundation
import MeetingCore

/// One user-picked camera-off file, copied into Application Support so the
/// original can move without losing the setting.
struct CameraOffItem: Hashable {
    var url: URL
    var displayName: String
}

/// Persisted loop + still + off-card copy for the camera-off feed.
/// Stored properties on the controller read these; do not bind SwiftUI
/// directly to computed UserDefaults getters (the @Observable trap).
enum CameraOffMedia {
    static let loopFilenameKey = "videoCameraOffLoopFilename"
    static let loopNameKey = "videoCameraOffLoopName"
    static let stillFilenameKey = "videoCameraOffStillFilename"
    static let stillNameKey = "videoCameraOffStillName"
    static let cardTitleKey = "videoCameraOffCardTitle"
    static let cardSubtitleKey = "videoCameraOffCardSubtitle"
    static let loopPrecomposedKey = "videoCameraOffLoopPrecomposed"

    static var directory: URL {
        let dir = Paths.applicationSupport.appendingPathComponent("camera-off", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var loop: CameraOffItem? { load(filenameKey: loopFilenameKey, nameKey: loopNameKey) }
    static var still: CameraOffItem? { load(filenameKey: stillFilenameKey, nameKey: stillNameKey) }

    /// Recorded 5s loops already include blur + mirror + logo. Imported files do not.
    static var loopIsPrecomposed: Bool {
        UserDefaults.standard.bool(forKey: loopPrecomposedKey)
    }

    static var cardTitle: String {
        get { UserDefaults.standard.string(forKey: cardTitleKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: cardTitleKey) }
    }

    static var cardSubtitle: String {
        get { UserDefaults.standard.string(forKey: cardSubtitleKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: cardSubtitleKey) }
    }

    static func importLoop(from source: URL, displayName: String? = nil, precomposed: Bool = false) throws -> CameraOffItem {
        var item = try importFile(from: source, slot: "loop", filenameKey: loopFilenameKey, nameKey: loopNameKey, defaultExt: "mov")
        if let displayName, !displayName.isEmpty {
            UserDefaults.standard.set(displayName, forKey: loopNameKey)
            item.displayName = displayName
        }
        UserDefaults.standard.set(precomposed, forKey: loopPrecomposedKey)
        return item
    }

    static func importStill(from source: URL) throws -> CameraOffItem {
        try importFile(from: source, slot: "still", filenameKey: stillFilenameKey, nameKey: stillNameKey, defaultExt: "png")
    }

    static func clearLoop() {
        clear(filenameKey: loopFilenameKey, nameKey: loopNameKey)
        UserDefaults.standard.removeObject(forKey: loopPrecomposedKey)
    }

    static func clearStill() {
        clear(filenameKey: stillFilenameKey, nameKey: stillNameKey)
    }

    // MARK: - Internals

    private static func load(filenameKey: String, nameKey: String) -> CameraOffItem? {
        guard let filename = UserDefaults.standard.string(forKey: filenameKey) else { return nil }
        let url = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let name = UserDefaults.standard.string(forKey: nameKey) ?? filename
        return CameraOffItem(url: url, displayName: name)
    }

    private static func importFile(
        from source: URL,
        slot: String,
        filenameKey: String,
        nameKey: String,
        defaultExt: String
    ) throws -> CameraOffItem {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }

        if let existing = UserDefaults.standard.string(forKey: filenameKey) {
            let old = directory.appendingPathComponent(existing)
            if FileManager.default.fileExists(atPath: old.path) {
                try? FileManager.default.removeItem(at: old)
            }
        }

        let ext = source.pathExtension.isEmpty ? defaultExt : source.pathExtension
        let filename = "\(slot).\(ext)"
        let dest = directory.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: source, to: dest)

        let displayName = source.lastPathComponent
        UserDefaults.standard.set(filename, forKey: filenameKey)
        UserDefaults.standard.set(displayName, forKey: nameKey)
        return CameraOffItem(url: dest, displayName: displayName)
    }

    private static func clear(filenameKey: String, nameKey: String) {
        if let existing = UserDefaults.standard.string(forKey: filenameKey) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(existing))
        }
        UserDefaults.standard.removeObject(forKey: filenameKey)
        UserDefaults.standard.removeObject(forKey: nameKey)
    }
}
