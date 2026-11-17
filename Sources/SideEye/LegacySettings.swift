import Foundation

/// The app was called Relay, and its settings lived first under an identifier it did not own and then
/// under one named after Relay. The first launch under the current identifier copies them across, so
/// favorites, the archive and every preference carry over. The old settings are left in place.
enum LegacySettings {
    /// Newest first: the first one that holds anything is the one to copy.
    static let oldDomains = ["io.github.jan-ebb.relay", "com.relay.sessions"]
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
        guard let bundleID = Bundle.main.bundleIdentifier, !oldDomains.contains(bundleID) else { return }
        let old = oldDomains.lazy.compactMap { UserDefaults.standard.persistentDomain(forName: $0) }.first { !$0.isEmpty }
        migrate(from: old, into: .standard)
    }
}
