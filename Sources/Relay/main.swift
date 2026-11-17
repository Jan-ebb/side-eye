import AppKit

MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    // Before anything reads a setting: bring them over from the identifier Relay used to have.
    LegacySettings.migrateIfNeeded()
    let delegate = AppDelegate()
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}
