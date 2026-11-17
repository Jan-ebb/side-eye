import AppKit
import Combine
import ServiceManagement

@MainActor
final class PreferencesModel: ObservableObject {
    enum Action {
        case moveOverlay, restoreArchived, refreshSources, configureInstinct, openFullDiskAccess
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
    /// Whether each app has left any data on this Mac for Relay to read.
    @Published private(set) var sourcePresent: [Source: Bool] = [:]
    @Published private(set) var instinctConfigured = false
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
        instinctConfigured = defaults?.string(forKey: "instinctRecipient")?.isEmpty == false
        sourcePresent = Dictionary(uniqueKeysWithValues: Source.allCases.map { ($0, Self.hasData($0)) })
        sourceEnabled = Dictionary(uniqueKeysWithValues: Source.allCases.map { ($0, $0.isEnabled(in: defaults)) })
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        loginItemNotice = nil
        do {
            let service = SMAppService.mainApp
            if enabled {
                try service.register()
                if service.status == .requiresApproval {
                    loginItemNotice = "Approve Relay in Login Items."
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

    func setSource(_ source: Source, enabled: Bool) {
        guard sourceEnabled[source] != enabled else { return }
        sourceEnabled[source] = enabled
        defaults?.set(enabled, forKey: source.enabledKey)
        store.refreshPreferences()
        refreshSources()
    }

    /// True when the app's own data folder exists, which is where Relay finds its chats.
    private static func hasData(_ source: Source) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = home.appending(path: "Library/Application Support")
        let folders: [URL]
        switch source {
        case .codex: folders = [home.appending(path: ".codex")]
        case .claude: folders = [home.appending(path: ".claude"), support.appending(path: "Claude/claude-code-sessions")]
        case .cursor: folders = [support.appending(path: "Cursor")]
        case .grok: folders = [support.appending(path: "Grok Bot")]
        case .instinct: return true
        }
        return folders.contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    func moveOverlay() { onAction?(.moveOverlay) }
    func restoreArchived() { onAction?(.restoreArchived) }
    func refreshSources() { onAction?(.refreshSources) }
    func configureInstinct() {
        onAction?(.configureInstinct)
        refreshSystemState()
    }
    func openFullDiskAccess() { onAction?(.openFullDiskAccess) }
}
