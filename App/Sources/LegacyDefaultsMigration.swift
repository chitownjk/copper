import Foundation

/// One-time copy of UserDefaults out of the old bundle identifier's domain.
///
/// The app shipped its M1 milestone as `com.meetingnotes.app`; that identifier
/// turned out to be registered to another team on Apple's portal, so it could
/// never be provisioned (E3.1/E4.1) and the bundle ID changed to
/// `com.strongrise.meetingcompanion`. UserDefaults is the only state keyed by
/// bundle ID — the database and audio live under a name-based Application
/// Support path, and Keychain items use a literal service string.
enum LegacyDefaultsMigration {
    static let legacyDomain = "com.meetingnotes.app"
    private static let markerKey = "didMigrateLegacyDefaults"

    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: markerKey) else { return }
        defaults.set(true, forKey: markerKey)

        guard let legacy = defaults.persistentDomain(forName: legacyDomain), !legacy.isEmpty else { return }
        for (key, value) in legacy where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }
}
