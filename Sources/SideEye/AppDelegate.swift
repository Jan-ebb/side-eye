import AppKit
import ApplicationServices
import SwiftUI

private let fixtureMode = CommandLine.arguments.contains("--ui-check") ||
    CommandLine.arguments.contains("--settings-check") || CommandLine.arguments.contains("--welcome-check")

/// The one call that still takes the front for an app without a Dock icon. Apple marks it as
/// deprecated in favour of `activate()`, which asks and is refused; reaching it through a protocol
/// keeps the build free of that warning.
@MainActor
private protocol FrontTaking {
    func activate(ignoringOtherApps flag: Bool)
}
extension NSApplication: FrontTaking {}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SessionStore(defaults: fixtureMode ? nil : .standard)
    private let defaults = UserDefaults.standard
    private lazy var preferences = PreferencesModel(store: store, defaults: fixtureMode ? nil : .standard)
    private var preferencesWindow: SettingsWindow?
    private var welcomeWindow: NSWindow?
    private var overlay: OverlayController?
    private var scanner: SessionScanner?
    private var hotkeys: Hotkeys?
    private var statusItem: NSStatusItem?
    private var wakeToken: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--self-test") {
            SelfChecks.run()
            NSApp.terminate(nil)
            return
        }

        if CommandLine.arguments.contains("--diagnostics") {
            SelfChecks.diagnoseLiveSources()
            return
        }
        let darkPreview = fixtureMode && ProcessInfo.processInfo.environment["SIDE_EYE_PREVIEW_APPEARANCE"] == "dark"
        NSApp.appearance = NSAppearance(named: darkPreview ? .darkAqua : .aqua)

        if CommandLine.arguments.contains("--settings-check") {
            loadSettingsFixture()
            return
        }
        if CommandLine.arguments.contains("--welcome-check") {
            showWelcome()
            return
        }

        let placementDefaults = fixtureMode
            ? UserDefaults(suiteName: "side-eye.fixture.\(ProcessInfo.processInfo.processIdentifier)")
            : defaults
        let overlay = OverlayController(store: store, placementDefaults: placementDefaults)
        self.overlay = overlay
        overlay.onOpen = { [weak self] in self?.open($0) }
        overlay.onHide = { [weak self] in self?.hide($0) }
        overlay.onLater = { [weak self] in self?.toggleLater($0) }
        overlay.onRestoreArchived = { [weak self] in self?.restoreArchived($0) }
        overlay.onArchiveRead = { [weak self] in self?.archiveRead() }
        overlay.onUndo = { [weak self] in self?.undoHide() }
        overlay.onShowSettings = { [weak self] in self?.showSettings() }
        preferences.onEdgeVisibility = { [weak overlay] in overlay?.setEdgeVisible($0) }
        preferences.onMuteNudges = { [weak overlay] in overlay?.clearAttentionNudge() }
        preferences.onAction = { [weak self] in self?.performPreferenceAction($0) }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.righthalf.inset.filled", accessibilityDescription: "Side Eye")
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "Side Eye chats"
        item.menu = makeStatusMenu()
        statusItem = item

        hotkeys = Hotkeys { [weak self] in self?.useShortcut($0) }
        preferences.unavailableShortcuts = Set(hotkeys?.unavailable ?? [])
        overlay.start(edgeVisible: preferences.edgeVisible)
        if CommandLine.arguments.contains("--ui-check") {
            overlay.start(edgeVisible: true)
            SelfChecks.checkOverlay(overlay, store: store, missing: hotkeys?.unavailable ?? [])
            return
        }
        let scanner = SessionScanner(receive: { [weak self] sessions in
            self?.store.ingest(sessions)
        }, receiveSummaries: { [weak self] sessions in
            self?.store.applySummaries(from: sessions)
        }, receiveGrokAgents: { [weak self] agents in
            self?.store.setGrokRoster(agents)
        })
        self.scanner = scanner
        scanner.start()
        showWelcomeOnFirstRun()
        wakeToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scanner?.refresh() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys?.stop()
        if let wakeToken { NSWorkspace.shared.notificationCenter.removeObserver(wakeToken) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let scanner else { return .terminateNow }
        Task {
            await scanner.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let entries: [(String, Selector, String)] = [
            ("Show chats", #selector(showSessions), ""),
            ("Show Archive", #selector(showArchive), ""),
            ("Add chat link…", #selector(addSessionLink), ""),
            ("Settings…", #selector(showSettings), ","),
            ("Welcome to Side Eye…", #selector(showWelcome), ""),
        ]
        for (title, action, key) in entries {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Side Eye", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func showSettings() {
        overlay?.close()
        preferences.refreshSystemState()
        let window: SettingsWindow
        if let preferencesWindow {
            window = preferencesWindow
        } else {
            let size = PreferencesView.windowSize
            window = SettingsWindow(contentRect: NSRect(origin: .zero, size: size),
                                    styleMask: [.titled, .closable, .resizable],
                                    backing: .buffered, defer: false)
            window.title = "Side Eye Settings"
            window.contentMinSize = NSSize(width: 470, height: 410)
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: PreferencesView(model: preferences, store: store))
            window.setContentSize(size)
            window.center()
            if !fixtureMode { window.setFrameAutosaveName("Side Eye Settings") }
            preferencesWindow = window
        }
        takeFront()
        window.orderFrontRegardless()
        window.makeKey()
    }

    /// Shows the welcome window to someone who has never run Side Eye, at every launch until they close
    /// it. From their first launch Side Eye also opens at login; the window's checkbox shows that and
    /// undoes it.
    private func showWelcomeOnFirstRun() {
        let launch = FirstLaunch.begin(in: defaults)
        if launch.isNewUser { preferences.openAtLoginForNewUser() }
        if launch.showsWelcome { showWelcome() }
    }

    @objc private func showWelcome() {
        preferences.refreshSystemState()
        if welcomeWindow == nil {
            var size = WelcomeView.windowSize(offersSummaries: preferences.hasSummaryServer)
            // On a short screen the window stays on it and its content scrolls.
            if let visible = NSScreen.main?.visibleFrame.height { size.height = min(size.height, visible - 60) }
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable],
                                  backing: .buffered, defer: false)
            window.title = "Welcome to Side Eye"
            window.isReleasedWhenClosed = false
            // No opening animation: it does not run while the display is asleep, which is when a login
            // item starts.
            window.animationBehavior = .none
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                   queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.welcomeClosed() }
            }
            window.contentViewController = NSHostingController(rootView: WelcomeView(
                model: preferences, store: store,
                showSideEye: { [weak self] in self?.overlay?.show(keyboard: true) },
                done: { [weak self] in self?.welcomeWindow?.close() }))
            window.setContentSize(size)
            window.center()
            welcomeWindow = window
        }
        takeFront()
        welcomeWindow?.orderFrontRegardless()
        welcomeWindow?.makeKey()
    }

    /// Makes Side Eye the active app before it shows a window. Side Eye has no Dock icon and is often
    /// started by a script, and then `activate()` alone is refused: the window opens behind whatever
    /// the person is looking at, or in front but drawn as inactive, with its switches washed out.
    private func takeFront() {
        (NSApp as FrontTaking).activate(ignoringOtherApps: true)
    }

    /// Closing the welcome window, with its button or the red one, is what counts as having seen it.
    private func welcomeClosed() {
        if !fixtureMode { FirstLaunch.welcomeClosed(in: defaults) }
    }

    private func performPreferenceAction(_ action: PreferencesModel.Action) {
        switch action {
        case .moveOverlay: overlay?.moveToPointerDisplay()
        case .restoreArchived: store.restoreHidden()
        case .refreshSources: scanner?.refresh()
        }
    }

    private func loadSettingsFixture() {
        let now = Date()
        store.ingest([
            Session(id: "fixture:main", source: .grok, title: "Fixture main", status: .idle, updatedAt: now,
                    route: .url("https://example.com")),
            Session(id: "fixture:side", source: .grok, title: "Fixture side", status: .idle, updatedAt: now,
                    route: .url("https://example.com")),
            Session(id: "fixture:codex", source: .codex, title: "Fixture Codex", status: .idle, updatedAt: now,
                    route: .url("https://example.com")),
        ])
        preferences.selection = .sources
        showSettings()
    }

    private func useShortcut(_ shortcut: Shortcut) {
        switch shortcut {
        case .overlay: overlay?.toggleKeyboard()
        case .next:
            if store.numberEntry != nil { overlay?.openEnteredNumber() }
            else { jumpToNext() }
        case .jumpNumber:
            overlay?.jumpByNumber()
        case .details:
            overlay?.toggleDetails()
        case .palette:
            overlay?.openPalette()
        case .archive:
            if overlay?.isShowing == true, store.filter == .archive { return }
            if overlay?.isShowing == true, store.filter == .favorites {
                overlay?.report(OverlayController.favoritesKeepNotice)
                return
            }
            if let session = store.removeTarget(allowSelection: overlay?.isShowing ?? false) {
                hide(session)
            } else {
                overlay?.report("Open Side Eye and select a chat to archive")
            }
        default:
            overlay?.useNumberShortcut(shortcut.rawValue)
        }
    }

    private func open(_ requested: Session) {
        guard let session = store.session(id: requested.id) else { return }
        overlay?.close()
        overlay?.clearAttentionNudge()
        if RouteOpener.open(session.route) {
            store.acknowledge(session)
        } else {
            overlay?.report("Couldn’t open this \(session.source.name) chat")
        }
    }

    private func hide(_ session: Session) {
        store.hide(session)
        overlay?.clearAttentionNudge()
        overlay?.report("Archived “\(session.title)”", undoable: true)
    }

    private func toggleLater(_ session: Session) {
        guard let deferred = store.toggleLater(session) else { return }
        overlay?.report(deferred ? "Moved “\(session.title)” to Later" : "Moved “\(session.title)” back to the Inbox",
                        undoable: true)
    }

    private func restoreArchived(_ session: Session) {
        if store.restoreArchived(session) { overlay?.report("Restored “\(session.title)” to the Inbox") }
    }

    private func archiveRead() {
        let count = store.archiveRead()
        overlay?.report(count == 0 ? "No read chats to archive"
                                   : "Archived \(count) read \(count == 1 ? "chat" : "chats")", undoable: count > 0)
    }

    @objc private func showSessions() { overlay?.show(keyboard: true) }
    @objc private func showArchive() { overlay?.showArchive() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func jumpToNext() {
        if let next = store.nextAttention() { open(next) }
        else { overlay?.report("You’re caught up") }
    }

    @objc private func undoHide() {
        overlay?.report(store.undoHide() ? "Last move undone" : "Nothing to undo")
    }

    @objc private func addSessionLink() {
        let alert = makeAlert("Add a chat link",
                              "Use a chat’s share or deep link to give it a shortcut in Side Eye.")
        let title = NSTextField(string: "")
        title.placeholderString = "Chat name"
        let link = NSTextField(string: "")
        link.placeholderString = "Chat URL"
        let sources = NSPopUpButton()
        sources.addItems(withTitles: Source.allCases.map(\.name))
        let stack = NSStackView(views: [title, link, sources])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        title.widthAnchor.constraint(equalToConstant: 286).isActive = true
        link.widthAnchor.constraint(equalTo: title.widthAnchor).isActive = true
        stack.frame = CGRect(origin: .zero, size: stack.fittingSize)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Add chat")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = title
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let label = title.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = link.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let supported = ["https", "codex", "claude", "cursor", "grok", "grokbot"]
        guard !label.isEmpty, let url = URL(string: address), let scheme = url.scheme?.lowercased(),
              supported.contains(scheme), (scheme != "https" || url.host != nil),
              Source.allCases.indices.contains(sources.indexOfSelectedItem) else {
            overlay?.report("Enter a chat name and a valid URL")
            return
        }
        let source = Source.allCases[sources.indexOfSelectedItem]
        defaults.set(true, forKey: source.enabledKey)
        store.addLink(title: String(label.prefix(120)), source: source, url: url)
        overlay?.show(keyboard: true)
    }

    private func makeAlert(_ title: String, _ message: String) -> NSAlert {
        overlay?.close()
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        return alert
    }
}


@MainActor
private final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command && event.charactersIgnoringModifiers?.lowercased() == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
