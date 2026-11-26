import AppKit
import Combine
import ServiceManagement

/// Where the summary model stands: not on this Mac, on its way, being checked, usable, or failed with
/// a sentence to show.
enum SummaryModelState: Equatable {
    case missing
    case downloading(received: Int64, total: Int64)
    case checking
    case ready
    case failed(String)
}

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
    /// Where the summary model stands on this Mac.
    @Published private(set) var summaryModel: SummaryModelState = .missing { didSet { syncSummaryNote() } }
    /// Whether llama.cpp, the program that runs the model, is installed.
    @Published private(set) var hasSummaryServer = false
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
    private var modelDownload: SummaryModelDownload?
    /// The model Settings offers. Checks point this at a small file on disk.
    var summaryModelFile = SummaryModel.pinned

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
        hasSummaryServer = LocalSummaryEngine.hasServer
        // A download in progress, or one that just failed, keeps saying so.
        if summaryModel == .missing || summaryModel == .ready {
            summaryModel = summaryModelFile.installed == nil ? .missing : .ready
        }
    }

    var canRemoveSummaryModel: Bool { summaryModelFile.isRemovable }

    /// Tells the sidebar whether to say that summaries are not installed. A model on its way does not
    /// count as missing. Checks, which have no settings, leave the sidebar alone.
    private func syncSummaryNote() {
        guard defaults != nil else { return }
        let missing: Bool
        switch summaryModel {
        case .missing, .failed: missing = true
        case .downloading, .checking, .ready: missing = false
        }
        if store.summaryModelMissing != missing { store.summaryModelMissing = missing }
    }

    /// Fetches the model. Only ever called from a button that names the download and its size.
    func downloadSummaryModel() {
        switch summaryModel {
        case .missing, .failed: break
        case .downloading, .checking, .ready: return
        }
        // One that broke off is kept, so it continues from where it stopped.
        let download = modelDownload ?? SummaryModelDownload(summaryModelFile) { [weak self] event in
            Task { @MainActor in self?.receive(event) }
        }
        modelDownload = download
        summaryModel = .downloading(received: 0, total: summaryModelFile.byteCount)
        download.start()
    }

    func cancelSummaryModelDownload() {
        modelDownload?.cancel()
        modelDownload = nil
        summaryModel = summaryModelFile.installed == nil ? .missing : .ready
    }

    func removeSummaryModel() {
        guard canRemoveSummaryModel else { return }
        localPreviewsEnabled = false
        try? FileManager.default.removeItem(at: summaryModelFile.downloaded)
        summaryModel = summaryModelFile.installed == nil ? .missing : .ready
    }

    private func receive(_ event: SummaryModelDownload.Event) {
        // An event that was already on its way when the download was cancelled changes nothing.
        guard modelDownload != nil else { return }
        switch event {
        case .progress(let received, let total):
            if case .downloading = summaryModel { summaryModel = .downloading(received: received, total: total) }
        case .checking:
            summaryModel = .checking
        case .finished:
            modelDownload = nil
            summaryModel = .ready
            // Asking for the model is asking for summaries, so they start without a second switch.
            if localPreviewsEnabled { refreshSources() } else { localPreviewsEnabled = true }
        case .failed(let message):
            summaryModel = .failed(message)
        }
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
            loginItemNotice = "Couldn’t change Open at login."
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
