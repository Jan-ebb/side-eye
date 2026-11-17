import Foundation

/// Relay's settings used to live under an app identifier it did not own. The first launch under the
/// current identifier copies them across, so favorites, the archive and every preference carry over.
/// The old settings are left in place.
enum LegacySettings {
    static let oldDomain = "com.relay.sessions"
    private static let marker = "migratedLegacySettings"

    /// Copies what `defaults` does not already have, once. Returns how many values it copied.
    @discardableResult
    static func migrate(from old: [String: Any]?, into defaults: UserDefaults) -> Int {
        guard defaults.object(forKey: marker) == nil else { return 0 }
        defaults.set(true, forKey: marker)
        var copied = 0
        for (key, value) in old ?? [:] where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
            copied += 1
        }
        return copied
    }

    static func migrateIfNeeded() {
        guard let bundleID = Bundle.main.bundleIdentifier, bundleID != oldDomain else { return }
        migrate(from: UserDefaults.standard.persistentDomain(forName: oldDomain), into: .standard)
    }
}
