import Foundation
import MeetingCore

/// One user-imported logo, copied into Application Support so the original
/// file can move or be replaced without losing the library entry.
struct SavedLogo: Identifiable, Hashable, Codable {
    let id: String
    var displayName: String
    let filename: String

    var url: URL { LogoLibrary.directory.appendingPathComponent(filename) }
}

/// Persisted list of uploaded logos. Selecting one applies it; Add copies a
/// new file in; Remove deletes that copy. Calendar auto-detect is out of scope.
enum LogoLibrary {
    static let listKey = "videoLogoLibrary"
    static let selectedIDKey = "videoLogoSelectedID"

    static var directory: URL {
        let dir = Paths.applicationSupport.appendingPathComponent("logos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func load() -> [SavedLogo] {
        guard let data = UserDefaults.standard.data(forKey: listKey),
              let logos = try? JSONDecoder().decode([SavedLogo].self, from: data)
        else { return [] }
        return logos.filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }

    static func save(_ logos: [SavedLogo]) {
        if let data = try? JSONEncoder().encode(logos) {
            UserDefaults.standard.set(data, forKey: listKey)
        }
    }

    static var selectedID: String? {
        get { UserDefaults.standard.string(forKey: selectedIDKey) }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: selectedIDKey)
            } else {
                UserDefaults.standard.removeObject(forKey: selectedIDKey)
            }
        }
    }

    /// Copies `source` into the library and returns the new record.
    static func importLogo(from source: URL, displayName: String? = nil) throws -> SavedLogo {
        let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension
        let id = UUID().uuidString.lowercased()
        let filename = "\(id).\(ext)"
        let dest = directory.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: source, to: dest)
        let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName: String
        if let name, !name.isEmpty {
            resolvedName = name
        } else {
            resolvedName = source.deletingPathExtension().lastPathComponent
        }
        return SavedLogo(id: id, displayName: resolvedName, filename: filename)
    }

    static func deleteFile(_ logo: SavedLogo) {
        try? FileManager.default.removeItem(at: logo.url)
    }
}
