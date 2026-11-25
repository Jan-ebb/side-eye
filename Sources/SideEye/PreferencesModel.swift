import AppKit
import Combine
import ServiceManagement

@MainActor
final class PreferencesModel: ObservableObject {
    enum Action {
        case moveOverlay, restoreArchived, refreshSources
    }

    @Published var selection: PreferencesSection = .general
    @Published var edgeVisible: Bool {
        didSet {
            guard edgeVisible != oldValue else { return }
            defaults?.set(edgeVisible, forKey: "edgeVisible")
            onEdgeVisibility?(edgeVisible)
        }
    }
    @Published var nudgesEnabled: Bool {
        didSet {
            guard nudgesEnabled != oldValue else { return }
            defaults?.set(!nudgesEnabled, forKey: "muteNudges")
            if !nudgesEnabled { onMuteNudges?() }
        }
    }
    @Published var localPreviewsEnabled: Bool {
        didSet {
            guard localPreviewsEnabled != oldValue else { return }
            defaults?.set(localPreviewsEnabled, forKey: SessionSummaryProvider.preferenceKey)
            refreshSources()
        }
    }
    @Published private(set) var launchAtLogin = false
    @Published private(set) var sourceEnabled: [Source: Bool]
    /// Whether each app has left any data on this Mac for Side Eye to read.
    @Published private(set) var sourcePresent: [Source: Bool] = [:]
    @Published private(set) var hasMultipleDisplays = false
    @Published var unavailableShortcuts: Set<Shortcut> = []
    @Published private(set) var loginItemNotice: String?

    var onEdgeVisibility: ((Bool) -> Void)?
    var onMuteNudges: (() -> Void)?
    var onAction: ((Action) -> Void)?

    private let defaults: UserDefaults?
    private let store: SessionStore

    init(store: SessionStore, defaults: UserDefaults? = .standard) {
        self.store = store
        self.defaults = defaults
        edgeVisible = defaults?.object(forKey: "edgeVisible") as? Bool ?? true
        nudgesEnabled = !(defaults?.bool(forKey: "muteNudges") ?? false)
        localPreviewsEnabled = defaults?.bool(forKey: SessionSummaryProvider.preferenceKey) ?? false
        sourceEnabled = Dictionary(uniqueKeysWithValues: Source.allCases.map { ($0, $0.isEnabled(in: defaults)) })
        refreshSystemState()
    }

    func refreshSystemState() {
        let loginStatus = SMAppService.mainApp.status
        launchAtLogin = loginStatus == .enabled || loginStatus == .requiresApproval
        hasMultipleDisplays = NSScreen.screens.count > 1
        sourcePresent = Dictionary(uniqueKeysWithValues: Source.allCases.map { ($0, $0.hasLocalData) })
        sourceEnabled = Dictionary(uniqueKeysWithValues: Source.allCases.map { ($0, $0.isEnabled(in: defaults)) })
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        loginItemNotice = nil
        do {
            let service = SMAppService.mainApp
            if enabled {
                try service.register()
                if service.status == .requiresApproval {
                    loginItemNotice = "Approve Side Eye in Login Items."
                    SMAppService.openSystemSettingsLoginItems()
                }
            } else {
                try service.unregister()
            }
        } catch {
            loginItemNotice = "Couldn’t update launch at login."
        }
        refreshSystemState()
    }

    /// Turns "Open at login" on for someone running Side Eye for the first time, so it is back after a
    /// restart without them having to find the setting. Unlike the switch it never opens System Settings.
    func openAtLoginForNewUser() {
        guard Self.canOpenAtLogin(from: Bundle.main.bundlePath) else { return }
        let service = SMAppService.mainApp
        try? service.register()
        if service.status == .requiresApproval { loginItemNotice = "Approve Side Eye in Login Items." }
        refreshSystemState()
    }

    /// Only an installed app can be opened at login. macOS runs a download that was never moved out of
    /// its folder from a temporary copy, whose path is gone by the next login, and a development build is
    /// a bare program with no app around it.
    nonisolated static func canOpenAtLogin(from bundlePath: String) -> Bool {
        bundlePath.hasSuffix(".app") && !bundlePath.contains("/AppTranslocation/")
    }

    func setSource(_ source: Source, enabled: Bool) {
        guard sourceEnabled[source] != enabled else { return }
        sourceEnabled[source] = enabled
        defaults?.set(enabled, forKey: source.enabledKey)
        store.refreshPreferences()
        refreshSources()
    }

    /// What the last scan found for an app, or why it found nothing. Nil while the app is off.
    func status(for source: Source) -> String? {
        guard sourceEnabled[source] == true else { return nil }
        if sourcePresent[source] == false { return "Not found on this Mac" }
        if store.isLoading { return "Looking for chats…" }
        let found = store.foundCount(for: source)
        if found == 0 { return source == .cursor || source == .grok ? "No chats in the last 48 hours" : "No recent chats" }
        let chats = "\(found) \(found == 1 ? "chat" : "chats")"
        guard source == .grok, store.grokMainOnly else { return chats }
        return "\(chats), \(store.foundCount(for: .grok, mainOnly: true)) from main agents"
    }

    func moveOverlay() { onAction?(.moveOverlay) }
    func restoreArchived() { onAction?(.restoreArchived) }
    func refreshSources() { onAction?(.refreshSources) }
}
