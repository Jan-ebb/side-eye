import AppKit
import ApplicationServices
import SwiftUI

private let fixtureMode = CommandLine.arguments.contains("--ui-check") ||
    CommandLine.arguments.contains("--settings-check")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SessionStore(defaults: fixtureMode ? nil : .standard)
    private let defaults = UserDefaults.standard
    private lazy var preferences = PreferencesModel(store: store, defaults: fixtureMode ? nil : .standard)
    private var preferencesWindow: SettingsWindow?
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
        let darkPreview = fixtureMode && ProcessInfo.processInfo.environment["RELAY_PREVIEW_APPEARANCE"] == "dark"
        NSApp.appearance = NSAppearance(named: darkPreview ? .darkAqua : .aqua)

        if CommandLine.arguments.contains("--settings-check") {
            loadSettingsFixture()
            return
        }

        let placementDefaults = fixtureMode
            ? UserDefaults(suiteName: "com.relay.sessions.fixture.\(ProcessInfo.processInfo.processIdentifier)")
            : defaults
        let overlay = OverlayController(store: store, placementDefaults: placementDefaults)
        self.overlay = overlay
        overlay.onOpen = { [weak self] in self?.open($0) }
        overlay.onHide = { [weak self] in self?.hide($0) }
        overlay.onLater = { [weak self] in self?.toggleLater($0) }
        overlay.onRestoreArchived = { [weak self] in self?.restoreArchived($0) }
        overlay.onUndo = { [weak self] in self?.undoHide() }
        overlay.onShowSettings = { [weak self] in self?.showSettings() }
        preferences.onEdgeVisibility = { [weak overlay] in overlay?.setEdgeVisible($0) }
        preferences.onMuteNudges = { [weak overlay] in overlay?.clearAttentionNudge() }
        preferences.onAction = { [weak self] in self?.performPreferenceAction($0) }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.righthalf.inset.filled", accessibilityDescription: "Relay")
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "Relay sessions"
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
        })
        self.scanner = scanner
        scanner.start()
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
            ("Show sessions", #selector(showSessions), ""),
            ("Show Archive", #selector(showArchive), ""),
            ("Add session link…", #selector(addSessionLink), ""),
            ("Settings…", #selector(showSettings), ","),
        ]
        for (title, action, key) in entries {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Relay", action: #selector(quit), keyEquivalent: "q")
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
            window.title = "Relay Settings"
            window.contentMinSize = NSSize(width: 470, height: 410)
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: PreferencesView(model: preferences, store: store))
            window.setContentSize(size)
            window.center()
            if !fixtureMode { window.setFrameAutosaveName("Relay Settings") }
            preferencesWindow = window
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func performPreferenceAction(_ action: PreferencesModel.Action) {
        switch action {
        case .moveOverlay: overlay?.moveToPointerDisplay()
        case .restoreArchived: store.restoreHidden()
        case .refreshSources: scanner?.refresh()
        case .configureInstinct: configureInstinct()
        case .openFullDiskAccess: openFullDiskAccess()
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
        case .archive:
            if overlay?.isShowing == true, store.filter == .archive { return }
            if let session = store.removeTarget(allowSelection: overlay?.isShowing ?? false) {
                hide(session)
            } else {
                overlay?.report("Open Relay and select a session to archive")
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
            overlay?.report("Couldn’t open this \(session.source.name) session")
        }
    }

    private func hide(_ session: Session) {
        store.hide(session)
        overlay?.clearAttentionNudge()
        overlay?.report("Session archived")
    }

    private func toggleLater(_ session: Session) {
        guard let deferred = store.toggleLater(session) else { return }
        overlay?.report(deferred ? "Moved to Later" : "Moved back to All")
    }

    private func restoreArchived(_ session: Session) {
        if store.restoreArchived(session) { overlay?.report("Session restored") }
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

    @objc private func configureInstinct() {
        let alert = makeAlert("Connect Instinct",
                              "Enter the phone number or email address of your one-to-one Instinct conversation in Messages. Allow Full Disk Access for Relay to detect replies.")
        let field = NSTextField(string: defaults.string(forKey: "instinctRecipient") ?? "")
        field.placeholderString = "Phone number or email"
        field.frame.size = NSSize(width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            defaults.removeObject(forKey: "instinctRecipient")
        } else if let recipient = DesktopProvider.normalizedRecipient(value) {
            defaults.set(recipient, forKey: "instinctRecipient")
            defaults.set(true, forKey: Source.instinct.enabledKey)
        } else {
            overlay?.report("Enter a valid phone number or email")
            return
        }
        scanner?.refresh()
    }

    @objc private func openFullDiskAccess() {
        let raw = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
        if let url = URL(string: raw) { NSWorkspace.shared.open(url) }
    }

    @objc private func addSessionLink() {
        let alert = makeAlert("Add a session link",
                              "Use a chat’s share or deep link to give it a shortcut in Relay.")
        let title = NSTextField(string: "")
        title.placeholderString = "Session name"
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
        alert.addButton(withTitle: "Add session")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = title
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let label = title.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = link.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let supported = ["https", "codex", "claude", "cursor", "grok", "grokbot", "sms", "imessage", "messages"]
        guard !label.isEmpty, let url = URL(string: address), let scheme = url.scheme?.lowercased(),
              supported.contains(scheme), (scheme != "https" || url.host != nil),
              Source.allCases.indices.contains(sources.indexOfSelectedItem) else {
            overlay?.report("Enter a session name and valid chat URL")
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
