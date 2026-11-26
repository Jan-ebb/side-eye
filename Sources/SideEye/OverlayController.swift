import AppKit
import QuartzCore
import SwiftUI

@MainActor
private final class OverlayPanel: NSPanel {
    var acceptsKeyboard = false
    var handleKey: ((NSEvent) -> Bool)?
    var handleMouse: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { acceptsKeyboard }
    override var canBecomeMain: Bool { false }

    init(name: String, size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        title = name
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
        hasShadow = true
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handleKey?(event) == true { return }
        if handleMouse?(event) == true { return }
        super.sendEvent(event)
    }
}

@MainActor
/// A menu item that runs a closure, for menus built by something that is not an object AppKit can target.
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(runClosure), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("Not used") }

    @objc private func runClosure() { run() }
}

private final class HoverHost<Content: View>: NSHostingView<Content> {
    var pointerChanged: ((Bool) -> Void)?
    /// Where the pointer is over this view, measured from its top-left corner, or nil once it has left.
    /// The tracking area is always active, so this reports while another app is in front.
    var pointerMoved: ((CGPoint?) -> Void)?
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let updated = NSTrackingArea(rect: .zero,
                                    options: [.inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .activeAlways],
                                    owner: self)
        addTrackingArea(updated)
        area = updated
    }

    override func mouseEntered(with event: NSEvent) {
        pointerChanged?(true)
        report(event)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        report(event)
    }

    override func mouseExited(with event: NSEvent) {
        pointerChanged?(false)
        pointerMoved?(nil)
    }

    private func report(_ event: NSEvent) {
        guard let pointerMoved else { return }
        let point = convert(event.locationInWindow, from: nil)
        pointerMoved(CGPoint(x: point.x, y: isFlipped ? point.y : bounds.height - point.y))
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class OverlayController {
    // Hover: the pill waits 20 ms, then expands and settles. Content fades in before the settle ends.
    // Exit: the outline returns to the pill in 100 ms, with reentry able to reverse it.
    private enum Timing {
        static let hoverOpen: Duration = .milliseconds(20)
        static let hoverExit: Duration = .milliseconds(25)
        static let contentReveal: TimeInterval = 0.140
        static let reentryCheck: Duration = .milliseconds(12)
    }

    private struct RailPress {
        let screen: NSScreen
        let startMouseY: CGFloat
        let startCenterY: CGFloat
        let beganInSidebar: Bool
        var isDragging = false
    }

    private static let railOffsetsKey = "railVerticalPositionByDisplay"
    private static let lastRailDisplayKey = "railLastDraggedDisplay"
    private static let revealAnimationKey = "sideEyeSidebarReveal"
    private let store: SessionStore
    private let placementDefaults: UserDefaults?
    private let railMotion = RailMotion()
    private let morph = SidebarMorph()
    private let sidebarMask = CALayer()
    private var railOffsets: [String: Double]
    private var selectedDisplayID: String?
    private var railPress: RailPress?
    private let rail = OverlayPanel(name: "Side Eye edge", size: OverlayMetrics.railSize)
    private let sidebar = OverlayPanel(name: "Side Eye chats", size: .init(width: OverlayMetrics.width, height: 200))
    private let nudge = OverlayPanel(name: "Side Eye nudge", size: OverlayMetrics.nudgeSize)
    private var screen: NSScreen?
    private var hoverTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?
    private var nudgeTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var queuedAttention: [Session] = []
    private var presentedNudgeSize = OverlayMetrics.nudgeSize
    private var displayToken: NSObjectProtocol?
    private var resignToken: NSObjectProtocol?
    private var menuTokens: [NSObjectProtocol] = []
    private var mouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var scrollMonitor: Any?
    /// Which row or palette entry the pointer is on.
    let pointer = PointerTracker()
    private var menuTrackingDepth = 0
    private var blockHoverUntil = Date.distantPast
    private var keyboardPinned = false
    private var keyboardSelectionLocation: NSPoint?
    private(set) var isEdgeVisible = true

    var onOpen: ((Session) -> Void)?
    var onHide: ((Session) -> Void)?
    var onShowWelcome: (() -> Void)?
    var onQuit: (() -> Void)?
    /// Puts a menu on screen. The on-screen checks replace it, since a real menu waits for a choice.
    var presentMenu: (NSMenu, NSPoint) -> Void = { menu, place in menu.popUp(positioning: nil, at: place, in: nil) }
    var onLater: ((Session) -> Void)?
    var onRestoreArchived: ((Session) -> Void)?
    var onArchiveRead: (() -> Void)?
    /// False while the keyboard checks run, so real input cannot disturb what they assert: a pointer
    /// resting on the test sidebar, a click or keystroke in another app that takes the focus away, or
    /// a key typed while the sidebar holds it.
    var followsPointer = true
    private var sendingTestKey = false
    var onUndo: (() -> Void)?
    var onShowSettings: (() -> Void)?
    var onShowSummarySettings: (() -> Void)?
    var onInstallUpdate: (() -> Void)?

    var isShowing: Bool { sidebar.isVisible }
    var isNudging: Bool { nudge.isVisible }

    func nudgeShowsSummary(_ summary: String) -> Bool {
        guard isNudging, let content = nudge.contentView as? NSHostingView<NudgeView> else { return false }
        return content.rootView.session?.stateSummary == summary
    }

    init(store: SessionStore, placementDefaults: UserDefaults? = .standard) {
        self.store = store
        self.placementDefaults = placementDefaults
        railOffsets = Self.loadRailOffsets(from: placementDefaults)
        selectedDisplayID = placementDefaults?.string(forKey: Self.lastRailDisplayKey)

        let railView = RailView(store: store, motion: railMotion, show: { [weak self] in self?.show(keyboard: false) })
        let railContent = HoverHost(rootView: railView)
        railContent.pointerChanged = { [weak self] entered in
            self?.pointerChanged(entered)
        }
        rail.contentView = railContent
        rail.handleMouse = { [weak self] event in self?.handleRailMouse(event) ?? false }

        let list = SidebarView(store: store, open: { [weak self] in self?.onOpen?($0) },
                               hide: { [weak self] in self?.onHide?($0) },
                               showMenu: { [weak self] in self?.showMoreMenu() },
                               showSummarySettings: { [weak self] in self?.onShowSummarySettings?() },
                               installUpdate: { [weak self] in self?.onInstallUpdate?() },
                               jump: { [weak self] in self?.jumpByNumber() },
                               search: { [weak self] in self?.beginSearch() },
                               toggleLater: { [weak self] in self?.onLater?($0) },
                               restoreArchived: { [weak self] in self?.onRestoreArchived?($0) },
                               undo: { [weak self] in self?.onUndo?() },
                               togglePin: { [weak self] in self?.togglePin($0) },
                               archiveRead: { [weak self] in self?.onArchiveRead?() },
                               runPalette: { [weak self] in self?.runPaletteEntry($0) },
                               onHighlightRow: { [weak self] in self?.highlightRow($0) },
                               pointer: pointer,
                               drawsSurface: false)
        let sidebarContent = HoverHost(rootView: list)
        sidebarContent.wantsLayer = true
        sidebarContent.pointerChanged = { [weak self] entered in self?.pointerChanged(entered) }
        sidebarContent.pointerMoved = { [weak self] point in self?.pointer.move(to: point) }
        pointer.showsPalette = { [weak self] in self?.store.palette != nil }
        sidebar.contentView = sidebarContent
        sidebar.hasShadow = false
        sidebarMask.backgroundColor = NSColor.black.cgColor
        sidebarMask.cornerCurve = .continuous
        sidebarMask.anchorPoint = CGPoint(x: 1, y: 0.5)
        sidebar.handleKey = { [weak self] event in self?.handleKey(event) ?? false }
        sidebar.handleMouse = { [weak self] event in self?.handleRailMouse(event, inSidebar: true) ?? false }

        store.onRowsChanged = { [weak self] in
            self?.position()
            self?.pruneAttention()
        }
        store.onAttention = { [weak self] in self?.attention($0) }
        let notifications = NotificationCenter.default
        displayToken = notifications.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                 object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.railPress = nil
                self?.screen = nil
                if self?.collapseTask != nil { self?.finishCollapse() }
                self?.position()
            }
        }
        resignToken = notifications.addObserver(forName: NSWindow.didResignKeyNotification,
                                                object: sidebar, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.followsPointer, self.isShowing, self.sidebar.acceptsKeyboard,
                      self.menuTrackingDepth == 0, !self.sidebar.isKeyWindow else { return }
                self.close()
            }
        }
        menuTokens.append(notifications.addObserver(forName: NSMenu.didBeginTrackingNotification,
                                                     object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.menuTrackingDepth += 1
                self.hoverTask?.cancel()
            }
        })
        menuTokens.append(notifications.addObserver(forName: NSMenu.didEndTrackingNotification,
                                                     object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.menuTrackingDepth = max(0, self.menuTrackingDepth - 1)
                if self.menuTrackingDepth == 0, self.isShowing, !self.keyboardPinned {
                    self.pointerChanged(false)
                }
            }
        })
    }

    func start(edgeVisible: Bool) {
        isEdgeVisible = edgeVisible
        position()
        if edgeVisible { rail.orderFrontRegardless() }
        syncRailMotion()
    }

    func setEdgeVisible(_ visible: Bool) {
        isEdgeVisible = visible
        if visible {
            moveToPointerDisplay()
            rail.orderFrontRegardless()
        } else {
            railPress = nil
            close()
            rail.orderOut(nil)
            hideNudge()
        }
        syncRailMotion()
    }

    func moveToPointerDisplay() {
        guard railPress?.isDragging != true else { return }
        screen = Self.screenAtPointer()
        selectedDisplayID = screen.flatMap(Self.displayID)
        position()
    }

    func toggleKeyboard() {
        if isShowing && keyboardPinned {
            close()
        } else {
            show(keyboard: true)
        }
    }

    func toggleDetails() {
        if store.numberEntry != nil {
            setNumberEntry(nil)
            if store.selectedID == nil { store.selectedID = store.shownRows.first?.id }
        }
        store.setShowsAllSummaries(!store.showsAllSummaries)
        if !isShowing { show(keyboard: true) }
    }

    func jumpByNumber() {
        if store.numberEntry != nil {
            typeJumpDigit("0")
            return
        }
        guard !store.shownRows.isEmpty else { report("No chats to open"); return }
        setNumberEntry("")
        if !keyboardPinned { show(keyboard: true) }
        store.selectedID = store.shownRows.first?.id
    }

    private func beginSearch() {
        setNumberEntry(nil)
        if !store.isSearching { store.setQuery("") }
        if !keyboardPinned { show(keyboard: true) }
    }

    func showArchive() {
        setNumberEntry(nil)
        store.setQuery(nil)
        store.setFilter(.archive)
        show(keyboard: true)
    }

    func useNumberShortcut(_ position: Int) {
        if store.numberEntry != nil {
            typeJumpDigit(String(position))
        } else if let session = store.session(in: position) {
            onOpen?(session)
        }
    }

    private func typeJumpDigit(_ digit: String) {
        let previous = store.numberEntry
        store.appendJumpDigit(digit)
        if store.numberEntry != previous { position() }
    }

    func openEnteredNumber() {
        if let session = store.enteredSession { onOpen?(session) }
        else { report("Enter a number shown in the list") }
    }

    private func setNumberEntry(_ entry: String?) {
        guard store.numberEntry != entry else { return }
        store.numberEntry = entry
        position()
    }

    func show(keyboard: Bool) {
        guard railPress?.isDragging != true else { return }
        hoverTask?.cancel()
        if keyboard { moveToPointerDisplay() }
        guard screen != nil else { position(); return }
        hideNudge()
        if !isShowing {
            store.selectedID = store.nextActionID ?? store.shownRows.first?.id
            store.keyboardMode = false
            keyboardSelectionLocation = NSEvent.mouseLocation
        }
        if keyboard {
            keyboardPinned = true
            keyboardSelectionLocation = NSEvent.mouseLocation
            store.keyboardMode = true
        }
        sidebar.acceptsKeyboard = true
        position()
        if !sidebar.isVisible {
            if let content = sidebar.contentView as? HoverHost<SidebarView> {
                content.rootView.presentation += 1
            }
            expandSidebar(animated: !keyboard)
        }
        installClickMonitors()
        sidebar.makeKey()
    }

    /// Opens the ⌘K palette, from inside the sidebar or from any app with ⌃⌥K.
    func openPalette(choosingLater: Bool = false) {
        if !isShowing || !keyboardPinned { show(keyboard: true) }
        setNumberEntry(nil)
        store.setQuery(nil)
        store.openPalette(choosingLater: choosingLater)
        position()
    }

    func closePalette() {
        guard store.palette != nil else { return }
        store.closePalette()
        position()
    }

    func close(morphing: Bool = false) {
        hoverTask?.cancel()
        if !morphing { blockHoverUntil = Date().addingTimeInterval(0.15) }
        let collapseFrom = morphing && isShowing && isEdgeVisible && !reduceMotion ? sidebarShape() : nil
        keyboardPinned = false
        keyboardSelectionLocation = nil
        store.keyboardMode = false
        pointer.move(to: nil)
        sidebar.acceptsKeyboard = false
        sidebar.orderOut(nil)
        clearContentReveal()
        if let collapseFrom { collapseSidebar(from: collapseFrom) }
        else { finishCollapse() }
        setNumberEntry(nil)
        store.closePalette()
        store.setQuery(nil)
        if store.filter == .archive { store.setFilter(.all) }
        removeClickMonitors()
        syncRailMotion()
    }

    private func highlightRow(_ id: String) {
        // Revealing or scrolling the list can move rows under a stationary pointer.
        guard followsPointer, store.numberEntry == nil, keyboardSelectionLocation != NSEvent.mouseLocation else { return }
        keyboardSelectionLocation = nil
        if !keyboardPinned { store.keyboardMode = false }
        if store.selectedID != id { store.selectedID = id }
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private var overlayColors: OverlayColors {
        OverlayColors(dark: sidebar.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    }

    private var pillCount: String? {
        let total = store.attentionCount
        if total == 0 { return nil }
        return total > 99 ? "99+" : String(total)
    }

    private var pillCountColor: NSColor {
        let colors = overlayColors
        return NSColor(store.count(for: .needsInput) > 0 ? colors.input : colors.review)
    }

    private func sidebarShape() -> SidebarMorph.Shape {
        let colors = overlayColors
        let border = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? colors.secondary : colors.divider
        return SidebarMorph.Shape(rect: sidebar.frame, radius: OverlayMetrics.sidebarCornerRadius,
                                  fill: NSColor(colors.surface), stroke: NSColor(border),
                                  countOpacity: 0, shadowOpacity: 0.25)
    }

    private func pillShape(phase: RailPhase) -> SidebarMorph.Shape {
        let colors = overlayColors
        let counted = pillCount != nil
        let size = RailView.pillSize(counted: counted, phase: phase)
        let rect = CGRect(x: rail.frame.maxX - OverlayMetrics.railPillRightInset - size.width,
                          y: rail.frame.midY - size.height / 2,
                          width: size.width, height: size.height)
        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let held = phase != .idle
        let surface = held ? colors.selection : colors.surface
        let fill = counted ? surface : colors.secondary.opacity(increaseContrast ? 1 : (held ? 0.84 : 0.55))
        let strokeOpacity = increaseContrast ? 1 : (held ? 0.66 : 0.28)
        let border = counted ? NSColor(colors.secondary).withAlphaComponent(strokeOpacity) : .clear
        return SidebarMorph.Shape(rect: rect, radius: size.width / 2, fill: NSColor(fill), stroke: border,
                                  countOpacity: counted ? 1 : 0, shadowOpacity: counted ? 0.12 : 0)
    }

    private func setPillVisible(_ visible: Bool) {
        guard railMotion.showsPill != visible else { return }
        railMotion.showsPill = visible
        rail.hasShadow = visible
    }

    /// Hover grows the pill into the sidebar. A keyboard shortcut shows it at once, like a launcher.
    private func expandSidebar(animated: Bool = true) {
        collapseTask?.cancel()
        collapseTask = nil
        let final = sidebarShape()
        let motion: SidebarMorph.Motion? = animated && isEdgeVisible && !reduceMotion ? .opening : nil
        let initial = motion != nil ? pillShape(phase: railMotion.phase) : final
        let presented = morph.transition(from: initial, to: final, count: pillCount,
                                         countColor: pillCountColor, motion: motion)
        setPillVisible(false)
        if motion != nil { revealSidebarContent(from: presented) }
        morph.window.orderFrontRegardless()
        sidebar.orderFrontRegardless()
    }

    private func revealSidebarContent(from start: SidebarMorph.Shape) {
        guard let layer = sidebar.contentView?.layer else { return }
        let frame = sidebar.frame
        let startY = layer.isGeometryFlipped ? frame.maxY - start.rect.maxY : start.rect.minY - frame.minY
        let startInSidebar = CGRect(x: start.rect.minX - frame.minX, y: startY,
                                    width: start.rect.width, height: start.rect.height)
        layer.mask = sidebarMask
        SidebarMorph.animateGeometry(of: sidebarMask, from: startInSidebar,
                                     to: CGRect(origin: .zero, size: frame.size),
                                     fromRadius: start.radius, toRadius: OverlayMetrics.sidebarCornerRadius,
                                     motion: .opening)
        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [0, 0, 1]
        opacity.keyTimes = [0, 0.27, 1]
        opacity.duration = Timing.contentReveal
        layer.add(opacity, forKey: Self.revealAnimationKey)
    }

    private func clearContentReveal() {
        sidebar.contentView?.layer?.mask = nil
        sidebar.contentView?.layer?.removeAnimation(forKey: Self.revealAnimationKey)
        sidebarMask.removeAllAnimations()
    }

    private func collapseSidebar(from start: SidebarMorph.Shape) {
        collapseTask?.cancel()
        let destination = pillShape(phase: .idle)
        let motion = SidebarMorph.Motion.retraction
        morph.transition(from: start, to: destination, count: pillCount, countColor: pillCountColor, motion: motion)
        let deadline = ContinuousClock.now.advanced(by: .seconds(motion.duration))
        collapseTask = Task { [weak self] in
            while ContinuousClock.now < deadline {
                try? await Task.sleep(for: Timing.reentryCheck)
                guard !Task.isCancelled, let self else { return }
                let point = NSEvent.mouseLocation
                if self.railPress == nil && (start.rect.contains(point) || self.rail.frame.contains(point)) {
                    self.show(keyboard: false)
                    return
                }
            }
            if !Task.isCancelled { self?.finishCollapse() }
        }
    }

    private func finishCollapse() {
        collapseTask?.cancel()
        collapseTask = nil
        setPillVisible(true)
        morph.hide()
    }

    /// Shows a short notice in the action bar. An undoable one offers Z beside it.
    func report(_ message: String, undoable: Bool = false) {
        store.notice = message
        store.noticeOffersUndo = undoable
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(undoable ? 5 : 3))
            guard !Task.isCancelled else { return }
            self?.store.notice = nil
            self?.store.noticeOffersUndo = false
        }
        if !isShowing {
            queuedAttention = []
            showNudge(message: message)
        }
    }

    func clearAttentionNudge() { hideNudge() }

    private func sendTestKey(_ text: String, code: UInt16, flags: NSEvent.ModifierFlags = []) {
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                        timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: sidebar.windowNumber, context: nil,
                                        characters: text, charactersIgnoringModifiers: text,
                                        isARepeat: false, keyCode: code) {
            sendingTestKey = true
            sidebar.sendEvent(event)
            sendingTestKey = false
        }
    }

    func checkHoverArrowInput() {
        precondition(isShowing && !keyboardPinned && !store.keyboardMode)
        precondition(morph.window.isVisible && !railMotion.showsPill,
                     "The morph should draw the only visible surface")
        if !reduceMotion {
            precondition(sidebar.contentView?.layer?.animation(forKey: Self.revealAnimationKey) != nil,
                         "The hover reveal should animate the sidebar content")
        }
        let rows = store.shownRows
        guard let selection = rows.firstIndex(where: { $0.id == store.selectedID }),
              selection + 1 < rows.count else {
            preconditionFailure("The hover fixture should have a selected row and a following row")
        }
        sendTestKey("\u{f701}", code: 125)
        precondition(store.selectedID == rows[selection + 1].id && !keyboardPinned)
        sendTestKey("\u{f700}", code: 126)
        precondition(store.selectedID == rows[selection].id)
        let originalOpen = onOpen
        defer { onOpen = originalOpen }
        var openedID: String?
        onOpen = { openedID = $0.id }
        sendTestKey("\r", code: 36)
        precondition(openedID == rows[selection].id, "Return should open the hover selection")
    }

    /// The row under the pointer becomes the selected one. The move is handed to the sidebar's view the
    /// way its window hands it one, so the check needs no real pointer.
    func checkPointerSelection() async {
        precondition(isShowing, "The pointer check needs the sidebar open")
        let rows = store.shownRows
        guard let host = sidebar.contentView as? HoverHost<SidebarView>,
              let other = rows.first(where: { $0.id != store.selectedID && pointer.frame(for: .row($0.id)) != nil }),
              let place = pointer.frame(for: .row(other.id)) else {
            preconditionFailure("No row said where it is, so the pointer could select nothing")
        }
        let wasFollowing = followsPointer, selectedBefore = store.selectedID
        followsPointer = true
        keyboardSelectionLocation = nil
        defer {
            followsPointer = wasFollowing
            pointer.move(to: nil)
            store.selectedID = selectedBefore
        }
        func point(at place: CGRect) {
            let inWindow = NSPoint(x: place.midX, y: host.bounds.height - place.midY)
            guard let event = NSEvent.mouseEvent(with: .mouseMoved, location: inWindow, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: sidebar.windowNumber, context: nil, eventNumber: 0,
                                                 clickCount: 0, pressure: 0) else {
                preconditionFailure("Could not make a pointer move")
            }
            host.mouseMoved(with: event)
        }
        point(at: place)
        try? await Task.sleep(for: .milliseconds(120))
        precondition(pointer.region == .row(other.id), "The sidebar should know which row the pointer is on")
        precondition(store.selectedID == other.id, "The row under the pointer should become the selected one")
    }

    /// The three dots in the sidebar open their menu, with Quit in it. The menu itself is not shown: a
    /// real one waits for a choice.
    func checkMoreMenuOpens() async {
        guard let host = sidebar.contentView as? HoverHost<SidebarView> else {
            preconditionFailure("The sidebar should be showing its list")
        }
        let originalPresent = presentMenu
        var offered: [String] = []
        presentMenu = { menu, _ in offered = menu.items.map(\.title) }
        host.rootView.showMenu()
        try? await Task.sleep(for: .milliseconds(60))
        presentMenu = originalPresent
        precondition(offered == ["Settings…", "Welcome to Side Eye…", "", "Quit Side Eye"],
                     "The three dots should open a menu that ends in Quit")
    }

    func checkLayoutAndKeyInput() {
        precondition(sidebar.isKeyWindow, "Keyboard sidebar should become key without activating Side Eye")
        precondition(sidebar.frame.maxX == pillShape(phase: .idle).rect.maxX,
                     "The sidebar and pill must share a right edge")
        if let visibleFrame = screen?.visibleFrame {
            precondition(sidebar.frame.maxY ==
                         RailPlacement.panelTop(for: sidebar.frame.height, near: rail.frame.maxY, in: visibleFrame))
        }
        precondition(rail.frame.width == OverlayMetrics.railSize.width)
        func press(_ text: String, code: UInt16, flags: NSEvent.ModifierFlags = []) {
            sendTestKey(text, code: code, flags: flags)
        }
        let startingLayout = store.showsAllSummaries
        press("d", code: 2)
        precondition(store.showsAllSummaries != startingLayout && !store.isSearching)
        press("d", code: 2)
        precondition(store.showsAllSummaries == startingLayout)
        press("g", code: 5)
        precondition(!store.isSearching, "Letters are commands; they must not start a search")
        press("/", code: 44)
        press("g", code: 5)
        precondition(store.query == "g" && store.shownRows.contains { $0.session.source == .grok })
        press("\u{1b}", code: 53)
        precondition(store.query.isEmpty && isShowing)
        press("\u{f701}", code: 125)
        precondition(store.selectedID == "one")
        let placeBeforeReading = store.shownRows.map(\.id)
        press("u", code: 32, flags: .command)
        precondition(store.rows.first { $0.id == "one" }?.statusLabel == "Read")
        precondition(store.shownRows.map(\.id) == placeBeforeReading, "Reading a chat must not move it")
        press("u", code: 32, flags: .command)
        precondition(store.rows.first { $0.id == "one" }?.statusLabel == "Review")
        let originalOpen = onOpen
        defer { onOpen = originalOpen }
        var openedID: String?
        onOpen = { openedID = $0.id }
        press("1", code: 18)
        precondition(openedID == "two", "The first number should open the top row")
        press("2", code: 19)
        precondition(openedID == "one", "The second number should open the second row")
        press("\u{f701}", code: 125, flags: .option)
        precondition(store.filter == .all && store.selectedID == "three", "⌥↓ should jump to the next group")
        press("\u{f701}", code: 125, flags: .option)
        precondition(store.selectedID == store.sections.last?.rows.first?.id, "⌥↓ should reach the last group")
        press("\u{f700}", code: 126, flags: .option)
        precondition(store.sections.count > 1 && store.selectedID == store.sections[store.sections.count - 2].rows.first?.id,
                     "⌥↑ should jump back a group")
        press("\t", code: 48)
        precondition(store.filter == .favorites, "Tab should switch to Favorites")
        press("\t", code: 48)
        precondition(store.filter == .later, "Tab should switch to Later")
        press("\t", code: 48)
        precondition(store.filter == .all, "Tab should switch back to the Inbox")
        press("\t", code: 48, flags: .shift)
        precondition(store.filter == .later)
        store.setFilter(.all)
        // ↑ and ↓ step through Favorites in the order the chats were starred.
        let starred = ["three", "one", "two"]
        for id in starred { if let row = store.rows.first(where: { $0.id == id }) { _ = store.togglePin(row.session) } }
        store.selectedID = "one"
        press("\t", code: 48)
        precondition(store.filter == .favorites && store.shownRows.map(\.id) == starred)
        precondition(store.selectedID == "one", "Favorites should keep a starred selection")
        press("\u{f701}", code: 125)
        precondition(store.selectedID == "two", "↓ should step down in Favorites")
        press("\u{f700}", code: 126)
        press("\u{f700}", code: 126)
        precondition(store.selectedID == "three", "↑ should step up in Favorites")
        if let previewDirectory = ProcessInfo.processInfo.environment["SIDE_EYE_PREVIEW_DIRECTORY"] {
            renderPreview(in: URL(fileURLWithPath: previewDirectory).appendingPathComponent("favorites"))
        }
        for id in starred { if let row = store.rows.first(where: { $0.id == id }) { _ = store.togglePin(row.session) } }
        store.setFilter(.all)
        store.selectedID = "three"
        let order = store.shownRows.map(\.id)
        press("f", code: 3)
        precondition(store.isPinned("three") && store.shownRows.map(\.id) == order,
                     "F should star the selected chat without moving it")
        press("p", code: 35)
        precondition(!store.isPinned("three"), "P should still work")
        press("k", code: 40, flags: .command)
        precondition(store.palette != nil && store.paletteTarget?.id == "three", "⌘K should open the palette on the selection")
        for (character, code) in [("f", 3), ("a", 0), ("v", 9)] { press(character, code: UInt16(code)) }
        precondition(store.selectedPaletteEntry?.action == .command(.pin), "Typing should filter the palette")
        press("\r", code: 36)
        precondition(store.palette == nil && store.isPinned("three"), "↵ should run the chosen command and close")
        press("p", code: 35)
        press("h", code: 4)
        precondition(store.palette?.choosingLater == true, "H should ask when the chat comes back")
        press("\u{1b}", code: 53)
        precondition(store.palette == nil)
        store.selectedID = "two"
        press("0", code: 29)
        precondition(store.numberEntry == "", "0 should open the number picker inside Side Eye")
        press("2", code: 19)
        press("\r", code: 36)
        precondition(openedID == "one", "Number entry should follow the grouped order")
        press("\u{1b}", code: 53)
        jumpByNumber()
        press("\u{f701}", code: 125)
        precondition(store.numberEntry == "1" && store.selectedID == "two")
        press("\u{f701}", code: 125)
        precondition(store.numberEntry == "2" && store.selectedID == "one")
        press("\u{1b}", code: 53)
        let twelfth = store.session(in: 12)?.id
        precondition(twelfth != nil)
        openedID = nil
        jumpByNumber()
        press("1", code: 18)
        press("2", code: 19)
        precondition(store.numberEntry == "12" && openedID == nil)
        let previewDirectory = ProcessInfo.processInfo.environment["SIDE_EYE_PREVIEW_DIRECTORY"].map(URL.init(fileURLWithPath:))
        if let previewDirectory { renderPreview(in: previewDirectory) }
        press("\r", code: 36)
        precondition(openedID == twelfth, "Entering 12 and Return should open the twelfth row")
        setNumberEntry(nil)
        store.selectedID = store.shownRows.first?.id

        press("/", code: 44)
        precondition(store.isSearching && store.query.isEmpty)
        press("e", code: 14)
        press("l", code: 37)
        press("d", code: 2)
        press("0", code: 29)
        precondition(store.query == "eld0" && store.count(for: .later) == 0 && store.numberEntry == nil
                     && store.showsAllSummaries == startingLayout, "Shortcut keys must type normally in search")
        press("\u{1b}", code: 53)
        precondition(!store.isSearching && isShowing)

        store.selectedID = "two"
        press("l", code: 37)
        precondition(!store.shownRows.contains { $0.id == "two" } && store.count(for: .later) == 1)
        store.setFilter(.later)
        if let previewDirectory { renderPreview(in: previewDirectory.appendingPathComponent("later")) }
        press("1", code: 18)
        precondition(openedID == "two", "Later should have its own numbered rows")
        press("e", code: 14)
        precondition(store.shownRows.isEmpty, "E should archive a selected Later row")
        showArchive()
        precondition(store.shownRows.map(\.id) == ["two"], "Archived chats must remain in the Archive list")
        if let previewDirectory { renderPreview(in: previewDirectory.appendingPathComponent("archive")) }
        openedID = nil
        press("1", code: 18)
        precondition(openedID == "two", "Archive should have its own numbered rows")
        press("e", code: 14)
        precondition(store.shownRows.map(\.id) == ["two"], "E should not archive the same chat twice")
        press("z", code: 6, flags: .command)
        precondition(store.shownRows.isEmpty)
        store.setFilter(.later)
        precondition(store.shownRows.map(\.id) == ["two"], "Undo should restore an archived row to Later")
        press("l", code: 37)
        precondition(store.shownRows.isEmpty && store.count(for: .later) == 0)
        store.setFilter(.all)
        precondition(store.shownRows.first?.id == "two", "L in Later should move the chat back to All")
        store.selectedID = store.shownRows.first?.id
        store.notice = nil
    }

    func checkSidebarDensity() {
        precondition(isShowing && !store.showsAllSummaries)
        let originalRows = store.shownRows
        let compactFrame = sidebar.frame
        let compactHeight = OverlayMetrics.sidebarHeight(for: store)

        store.setShowsAllSummaries(true)
        precondition(store.shownRows == originalRows, "Layout should preserve row order")
        precondition(OverlayMetrics.sidebarHeight(for: store) > compactHeight,
                     "Previews add a line under each row, so they need a taller panel")
        precondition(sidebar.frame.maxX == compactFrame.maxX, "Both layouts must keep the pill's right edge")
        if let path = ProcessInfo.processInfo.environment["SIDE_EYE_PREVIEW_DIRECTORY"] {
            renderPreview(in: URL(fileURLWithPath: path).appendingPathComponent("briefing"))
        }

        store.setShowsAllSummaries(false)
        precondition(sidebar.frame == compactFrame, "Compact should return to its original frame")
    }

    func checkPointer() async -> Bool? {
        guard CGPreflightPostEventAccess(), let primary = NSScreen.screens.first else { return nil }
        let original = NSEvent.mouseLocation
        let target = CGPoint(x: rail.frame.midX, y: rail.frame.midY)
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier

        func move(_ point: CGPoint) {
            postMouse(.mouseMoved, at: point, primaryTop: primary.frame.maxY)
        }

        // Let a previous close finish suppressing accidental immediate reentry.
        try? await Task.sleep(for: .milliseconds(280))
        move(CGPoint(x: rail.frame.minX - 50, y: rail.frame.midY + 55))
        try? await Task.sleep(for: .milliseconds(80))
        move(target)
        try? await Task.sleep(for: .milliseconds(85))
        guard rail.frame.contains(NSEvent.mouseLocation) else { return nil }
        defer { move(original) }
        let rightEdge = pillShape(phase: .idle).rect.maxX
        if reduceMotion {
            try? await Task.sleep(for: .milliseconds(235))
        } else {
            var widest: CGFloat = 0
            let end = ContinuousClock.now.advanced(by: .milliseconds(235))
            repeat {
                guard rail.frame.contains(NSEvent.mouseLocation) else { return nil }
                guard let rendered = morph.presentedFrame, abs(rendered.maxX - rightEdge) < 0.6 else {
                    print("Hover fixture: the expanding outline lost its right edge anchor.")
                    return false
                }
                widest = max(widest, rendered.width)
                try? await Task.sleep(for: .milliseconds(12))
            } while ContinuousClock.now < end
            guard (1...5).contains(widest - sidebar.frame.width),
                  let settled = morph.presentedFrame, abs(settled.width - sidebar.frame.width) < 0.6 else {
                print("Hover fixture: the opening did not make a small rebound and settle.")
                return false
            }
        }
        guard isShowing, !store.keyboardMode, morph.window.isVisible, !railMotion.showsPill else {
            print("Hover fixture at the rail: visible=\(isShowing), pill=\(railMotion.showsPill).")
            return false
        }

        let inside = CGPoint(x: sidebar.frame.maxX - 64, y: rail.frame.midY)
        move(inside)
        try? await Task.sleep(for: .milliseconds(260))
        let rows = store.shownRows
        guard isShowing, sidebar.isKeyWindow,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost,
              let selected = rows.firstIndex(where: { $0.id == store.selectedID }),
              selected + 1 < rows.count else {
            print("Hover fixture after entering the sidebar: visible=\(isShowing), key=\(sidebar.isKeyWindow).")
            return false
        }
        postKey(125)
        try? await Task.sleep(for: .milliseconds(120))
        guard store.selectedID == rows[selected + 1].id else { return false }
        postKey(126)
        try? await Task.sleep(for: .milliseconds(120))
        guard store.selectedID == rows[selected].id else { return false }

        // The pointer selects the row it is on, so the keys and the bar under the list act on that row.
        guard let other = rows.first(where: { $0.id != store.selectedID && pointer.frame(for: .row($0.id)) != nil }),
              let place = pointer.frame(for: .row(other.id)) else {
            print("Hover fixture: no row said where it is.")
            return false
        }
        move(CGPoint(x: sidebar.frame.minX + place.midX, y: sidebar.frame.maxY - place.midY))
        try? await Task.sleep(for: .milliseconds(140))
        guard store.selectedID == other.id, !store.keyboardMode else {
            print("Hover fixture: the row under the pointer was not selected (\(store.selectedID ?? "none"), wanted \(other.id)).")
            return false
        }

        let outside = CGPoint(x: sidebar.frame.minX - 12, y: rail.frame.midY)
        move(outside)
        if !reduceMotion {
            try? await Task.sleep(for: .milliseconds(55))
            guard !isShowing, collapseTask != nil, morph.window.isVisible else {
                print("Hover fixture did not start collapsing.")
                return false
            }
            guard let rendered = morph.presentedFrame, abs(rendered.maxX - rightEdge) < 0.6 else {
                print("Hover fixture: the retracting outline lost its right edge anchor.")
                return false
            }
            move(inside)
            try? await Task.sleep(for: .milliseconds(75))
            guard isShowing, collapseTask == nil, !railMotion.showsPill else {
                print("Hover fixture did not reverse the collapse on reentry.")
                return false
            }
            move(outside)
        }
        try? await Task.sleep(for: .milliseconds(200))
        let dismissed = !isShowing && !morph.window.isVisible && railMotion.showsPill
        if !dismissed {
            print("Hover fixture after exit: visible=\(isShowing), phase=\(railMotion.phase).")
        }
        return dismissed
    }

    func checkRailDrag() async -> Bool? {
        guard CGPreflightPostEventAccess(), let primary = NSScreen.screens.first, let originalScreen = screen,
              let id = Self.displayID(originalScreen), let placementDefaults else { return nil }
        let originalPointer = NSEvent.mouseLocation
        let originalFrame = rail.frame
        let originalOffsets = railOffsets
        let originalDisplay = selectedDisplayID
        let origin = CGPoint(x: originalFrame.midX, y: originalFrame.midY)
        let visible = originalScreen.visibleFrame
        let destination = CGPoint(x: origin.x - 48, y: visible.minY + originalFrame.height / 2 + 40)
        let primaryTop = primary.frame.maxY
        var pressed = false
        defer {
            if pressed { postMouse(.leftMouseUp, at: NSEvent.mouseLocation, primaryTop: primaryTop) }
            railPress = nil
            syncRailMotion()
            close()
            railOffsets = originalOffsets
            selectedDisplayID = originalDisplay
            screen = originalScreen
            placementDefaults.removeObject(forKey: Self.railOffsetsKey)
            placementDefaults.removeObject(forKey: Self.lastRailDisplayKey)
            position()
            postMouse(.mouseMoved, at: originalPointer, primaryTop: primaryTop)
        }
        try? await Task.sleep(for: .milliseconds(180))
        postMouse(.mouseMoved, at: CGPoint(x: origin.x - 80, y: origin.y + 55), primaryTop: primaryTop)
        try? await Task.sleep(for: .milliseconds(80))
        postMouse(.mouseMoved, at: origin, primaryTop: primaryTop)
        try? await Task.sleep(for: .milliseconds(275))
        guard rail.frame.contains(NSEvent.mouseLocation) else { return nil }
        guard isShowing else { return false }

        // The three dots and the drag start both share the rail's hit area. A click on the dots has to
        // open their menu, with Quit in it, and not begin a drag.
        let headerHeight = OverlayMetrics.compactToolbarHeight
        let dotsInset: CGFloat = 21
        let dots = CGPoint(x: sidebar.frame.maxX - OverlayMetrics.sidebarInset - dotsInset,
                           y: sidebar.frame.maxY - OverlayMetrics.sidebarInset - headerHeight / 2)
        if rail.frame.contains(dots) {
            let originalPresent = presentMenu
            var offered: [String] = []
            presentMenu = { menu, _ in offered = menu.items.map(\.title) }
            postMouse(.leftMouseDown, at: dots, primaryTop: primaryTop)
            postMouse(.leftMouseUp, at: dots, primaryTop: primaryTop)
            try? await Task.sleep(for: .milliseconds(90))
            presentMenu = originalPresent
            guard offered.contains("Quit Side Eye"), railPress == nil else {
                print("Rail fixture: the click on the sidebar's three dots was intercepted.")
                return false
            }
            postMouse(.mouseMoved, at: origin, primaryTop: primaryTop)
        }

        postMouse(.leftMouseDown, at: origin, primaryTop: primaryTop)
        pressed = true
        try? await Task.sleep(for: .milliseconds(80))
        guard railMotion.phase == .pressed else { return false }
        postMouse(.leftMouseDragged, at: CGPoint(x: origin.x, y: origin.y - 10), primaryTop: primaryTop)
        try? await Task.sleep(for: .milliseconds(65))
        postMouse(.leftMouseDragged, at: destination, primaryTop: primaryTop)
        try? await Task.sleep(for: .milliseconds(150))
        guard railPress?.isDragging == true, railMotion.phase == .dragging, !isShowing,
              rail.frame.minX == originalFrame.minX,
              abs(rail.frame.midY - destination.y) <= 1 else { return false }

        postMouse(.leftMouseUp, at: destination, primaryTop: primaryTop)
        pressed = false
        try? await Task.sleep(for: .milliseconds(100))
        guard railPress == nil, railMotion.phase == .idle,
              placementDefaults.string(forKey: Self.lastRailDisplayKey) == id,
              let saved = Self.loadRailOffsets(from: placementDefaults)[id] else { return false }

        let movedFrame = rail.frame
        screen = nil
        railOffsets = [id: saved]
        selectedDisplayID = placementDefaults.string(forKey: Self.lastRailDisplayKey)
        position()
        return rail.frame == movedFrame && sidebar.frame.minY >= visible.minY && sidebar.frame.maxY <= visible.maxY
    }

    private func postMouse(_ type: CGEventType, at point: CGPoint, primaryTop: CGFloat) {
        let screenPoint = CGPoint(x: point.x, y: primaryTop - point.y)
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: screenPoint,
                mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    func checkGlobalToggle() async -> Bool? {
        guard CGPreflightPostEventAccess() else { return nil }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        postGlobalShortcut(.overlay)
        try? await Task.sleep(for: .milliseconds(250))
        return isShowing && store.keyboardMode &&
            NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost
    }

    func checkGlobalArchive() async -> Bool {
        guard let id = store.selectedID else { return false }
        let count = store.rows.count
        postGlobalShortcut(.archive)
        try? await Task.sleep(for: .milliseconds(250))
        return store.rows.count == count - 1 && !store.rows.contains { $0.id == id }
    }

    func checkGlobalNumberPicker() async -> Bool {
        postGlobalShortcut(.jumpNumber)
        try? await Task.sleep(for: .milliseconds(250))
        return isShowing && store.keyboardMode && store.numberEntry == ""
    }

    func checkGlobalDetailsToggle() async -> Bool {
        let initial = store.showsAllSummaries
        let rows = store.shownRows.map(\.id)
        postGlobalShortcut(.details)
        try? await Task.sleep(for: .milliseconds(250))
        guard isShowing, store.showsAllSummaries != initial else { return false }
        postGlobalShortcut(.details)
        try? await Task.sleep(for: .milliseconds(250))
        return isShowing && store.showsAllSummaries == initial && store.shownRows.map(\.id) == rows
    }

    func checkGlobalFilteredNumber() async -> Bool {
        let originalOpen = onOpen
        let originalFilter = store.filter
        defer {
            onOpen = originalOpen
            store.setFilter(originalFilter)
        }
        store.setFilter(.toReview)
        guard let expected = store.shownRows.first?.id else { return false }
        var openedID: String?
        onOpen = { openedID = $0.id }
        postGlobalShortcut(.one)
        try? await Task.sleep(for: .milliseconds(250))
        return openedID == expected
    }

    private func postGlobalShortcut(_ shortcut: Shortcut) {
        postKey(CGKeyCode(shortcut.keyCode), flags: [.maskControl, .maskAlternate])
    }

    private func postKey(_ code: CGKeyCode, flags: CGEventFlags = []) {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    func renderPreview(in directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let panels: [(String, OverlayPanel)]
        if isNudging, let session = queuedAttention.first {
            panels = [(session.status == .needsInput ? "Input nudge" : "Review nudge", nudge)]
        } else if store.numberEntry != nil {
            panels = [("Number picker", sidebar)]
        } else {
            panels = [("Sidebar", sidebar), ("Edge", rail)]
        }
        for (name, panel) in panels {
            guard let view = previewView(for: panel) else { continue }
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?
                .write(to: directory.appendingPathComponent(name + ".png"))
        }
    }

    /// Draws the sidebar as it is on screen rather than a fresh copy, so rows SwiftUI failed to redraw show up.
    func renderLiveSidebar(to url: URL) {
        guard let view = sidebar.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Switches from the grouped Inbox to Favorites on screen, where starred chats leave their groups.
    func checkTabSwitchRedraw(previewDirectory: URL?) async {
        store.setFilter(.all)
        let starred = ["three", "one", "two"]
        for id in starred { if let row = store.rows.first(where: { $0.id == id }) { _ = store.togglePin(row.session) } }
        store.selectedID = "one"
        try? await Task.sleep(for: .milliseconds(250))
        if let previewDirectory { renderLiveSidebar(to: previewDirectory.appendingPathComponent("live-inbox.png")) }
        sendTestKey("\t", code: 48)
        try? await Task.sleep(for: .milliseconds(350))
        if let previewDirectory { renderLiveSidebar(to: previewDirectory.appendingPathComponent("live-favorites.png")) }
        sendTestKey("\u{f701}", code: 125)
        try? await Task.sleep(for: .milliseconds(350))
        precondition(store.filter == .favorites && store.selectedID == "two")
        sendTestKey("\u{7f}", code: 51)
        precondition(store.rows.contains { $0.id == "two" } && store.notice == Self.favoritesKeepNotice,
                     "Delete must not archive from Favorites")
        if let previewDirectory { renderLiveSidebar(to: previewDirectory.appendingPathComponent("live-favorites-down.png")) }
        for id in starred { if let row = store.rows.first(where: { $0.id == id }) { _ = store.togglePin(row.session) } }
        store.setFilter(.all)
    }

    /// ⇧E clears read replies in one step, Z brings them back, and R restores a chat from Archive.
    func checkArchiveKeys() {
        store.setFilter(.all)
        precondition(isShowing && store.readReplyCount == 1, "The fixture should hold one read reply")
        let inbox = store.shownRows.map(\.id)
        sendTestKey("E", code: 14, flags: .shift)
        precondition(store.readReplyCount == 0 && store.shownRows.count == inbox.count - 1,
                     "⇧E should archive every read reply and nothing else")
        sendTestKey("z", code: 6)
        precondition(store.shownRows.map(\.id) == inbox, "Z should undo archive all read")
        store.selectedID = "row-6"
        sendTestKey("e", code: 14)
        precondition(!store.rows.contains { $0.id == "row-6" }, "E should still archive one chat")
        showArchive()
        store.selectedID = "row-6"
        sendTestKey("e", code: 14, flags: .shift)
        precondition(store.filter == .archive, "⇧E should do nothing outside the Inbox")
        sendTestKey("r", code: 15)
        precondition(store.rows.contains { $0.id == "row-6" }, "R should restore the selected chat from Archive")
        store.setFilter(.all)
        store.selectedID = store.shownRows.first?.id
        store.notice = nil
    }

    private func previewView(for panel: OverlayPanel) -> NSView? {
        if let host = panel.contentView as? NSHostingView<SidebarView> {
            var root = host.rootView
            root.drawsSurface = true
            let preview = NSHostingView(rootView: root)
            preview.frame = host.bounds
            preview.appearance = panel.effectiveAppearance
            return preview
        }
        if let host = panel.contentView as? NSHostingView<RailView> {
            var root = host.rootView
            root.motion = RailMotion()
            let preview = NSHostingView(rootView: root)
            preview.frame = host.bounds
            preview.appearance = panel.effectiveAppearance
            return preview
        }
        return panel.contentView
    }

    private func position() {
        guard railPress?.isDragging != true else { return }
        if screen == nil {
            screen = selectedDisplayID.flatMap { id in
                NSScreen.screens.first { Self.displayID($0) == id }
            } ?? Self.screenAtPointer()
        }
        guard let screen else { return }
        let frame = screen.visibleFrame
        let savedFraction = Self.displayID(screen).flatMap { railOffsets[$0] }
        let railFrame = RailPlacement.railFrame(in: frame, size: OverlayMetrics.railSize, fraction: savedFraction)
        let availableHeight = max(1, frame.height - 2 * RailPlacement.screenInset)
        let height = min(availableHeight, OverlayMetrics.sidebarHeight(for: store))
        let sidebarTop = RailPlacement.panelTop(for: height, near: railFrame.maxY, in: frame)
        let sidebarRight = railFrame.maxX - (isEdgeVisible ? OverlayMetrics.railPillRightInset : 3)
        let sidebarFrame = NSRect(x: sidebarRight - OverlayMetrics.width, y: sidebarTop - height,
                                  width: OverlayMetrics.width, height: height)
        let nudgeHeight = min(availableHeight, presentedNudgeSize.height)
        let nudgeTop = RailPlacement.panelTop(for: nudgeHeight, near: railFrame.maxY, in: frame)
        let nudgeRight = isEdgeVisible ? railFrame.minX - 5 : sidebarRight
        let nudgeFrame = NSRect(x: nudgeRight - presentedNudgeSize.width,
                                y: nudgeTop - nudgeHeight,
                                width: presentedNudgeSize.width, height: nudgeHeight)
        let railMoved = rail.frame != railFrame
        let sidebarMoved = sidebar.frame != sidebarFrame
        if railMoved { rail.setFrame(railFrame, display: rail.isVisible) }
        if sidebarMoved { sidebar.setFrame(sidebarFrame, display: sidebar.isVisible) }
        if nudge.frame != nudgeFrame { nudge.setFrame(nudgeFrame, display: nudge.isVisible) }
        if isShowing && (railMoved || sidebarMoved) {
            let shape = sidebarShape()
            morph.transition(from: shape, to: shape, count: pillCount, countColor: pillCountColor)
            clearContentReveal()
        } else if railMoved && collapseTask != nil {
            finishCollapse()
        }
        syncRailMotion()
    }

    private func syncRailMotion() {
        let phase: RailPhase
        if let press = railPress {
            phase = press.isDragging ? .dragging : .pressed
        } else {
            phase = .idle
        }
        if railMotion.phase != phase { railMotion.phase = phase }
    }

    private static func screenAtPointer() -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    }

    private static func displayID(_ screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        if let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() {
            return CFUUIDCreateString(nil, uuid) as String
        }
        return "display-\(number.uint32Value)"
    }

    private static func loadRailOffsets(from defaults: UserDefaults?) -> [String: Double] {
        defaults?.dictionary(forKey: railOffsetsKey) as? [String: Double] ?? [:]
    }

    private func handleRailMouse(_ event: NSEvent, inSidebar: Bool = false) -> Bool {
        switch event.type {
        case .leftMouseDown:
            let mouse = NSEvent.mouseLocation
            guard isEdgeVisible, let screen, !inSidebar || rail.frame.contains(mouse) else { return false }
            hoverTask?.cancel()
            railPress = RailPress(screen: screen, startMouseY: mouse.y, startCenterY: rail.frame.midY,
                                  beganInSidebar: inSidebar)
            syncRailMotion()
            // The sidebar sits above the rail. Let its controls handle an ordinary click here.
            return !inSidebar
        case .leftMouseDragged:
            guard var press = railPress else { return false }
            let mouseY = NSEvent.mouseLocation.y
            if !press.isDragging {
                guard abs(mouseY - press.startMouseY) >= 4 else { return !press.beganInSidebar }
                press.isDragging = true
                railPress = press
                syncRailMotion()
                close()
            }
            let frame = RailPlacement.railFrame(in: press.screen.visibleFrame, size: OverlayMetrics.railSize,
                                                fraction: dragFraction(for: press, mouseY: mouseY))
            if frame.origin != rail.frame.origin { rail.setFrameOrigin(frame.origin) }
        case .leftMouseUp:
            guard let press = railPress else { return false }
            railPress = nil
            if press.isDragging {
                screen = press.screen
                if let id = Self.displayID(press.screen) {
                    selectedDisplayID = id
                    railOffsets[id] = dragFraction(for: press, mouseY: NSEvent.mouseLocation.y)
                    placementDefaults?.set(railOffsets, forKey: Self.railOffsetsKey)
                    placementDefaults?.set(id, forKey: Self.lastRailDisplayKey)
                }
                blockHoverUntil = Date().addingTimeInterval(0.15)
                position()
                if abs(rail.frame.midY - press.startCenterY) >= 0.5 {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
            } else if !press.beganInSidebar && rail.frame.contains(NSEvent.mouseLocation) {
                show(keyboard: false)
            }
            syncRailMotion()
            if press.beganInSidebar && !press.isDragging {
                pointerChanged(false)
                return false
            }
        default:
            return false
        }
        return true
    }

    private func dragFraction(for press: RailPress, mouseY: CGFloat) -> Double {
        RailPlacement.fraction(forCenterY: press.startCenterY + mouseY - press.startMouseY,
                               in: press.screen.visibleFrame, size: OverlayMetrics.railSize)
    }

    private func pointerChanged(_ entered: Bool) {
        guard railPress == nil, !keyboardPinned, menuTrackingDepth == 0 else { return }
        hoverTask?.cancel()
        if isShowing {
            // Ordering the sidebar in during a reversal can queue stale enter/exit events.
            // Use the pointer's current position to decide whether to retract.
            let point = NSEvent.mouseLocation
            guard !rail.frame.contains(point), !sidebar.frame.contains(point) else { return }
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: Timing.hoverExit)
                guard !Task.isCancelled, let self, !self.keyboardPinned, self.menuTrackingDepth == 0 else { return }
                let point = NSEvent.mouseLocation
                if !self.rail.frame.contains(point), !self.sidebar.frame.contains(point) {
                    self.close(morphing: true)
                }
            }
        } else if entered && Date() >= blockHoverUntil {
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: Timing.hoverOpen)
                guard !Task.isCancelled, let self,
                      self.rail.frame.contains(NSEvent.mouseLocation) else { return }
                self.show(keyboard: false)
                if self.isShowing {
                    NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                }
            }
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        // During the scripted checks only their own keys count; anything typed for real is dropped.
        if !followsPointer && !sendingTestKey { return true }
        guard isShowing, sidebar.acceptsKeyboard else { return false }
        let flags = event.modifierFlags.intersection([.shift, .control, .option, .command])
        if store.palette != nil {
            handlePaletteKey(event, flags: flags)
            return true
        }
        if flags == [.command] {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "k":
                openPalette()
                return true
            case "z":
                onUndo?()
                return true
            case "u":
                if let row = store.shownRows.first(where: { $0.id == store.selectedID }) {
                    if row.needsReview { store.markRead(row.session) }
                    else { store.markUnread(row.session) }
                }
                return true
            case ",":
                onShowSettings?()
                return true
            default:
                return false
            }
        }
        // ⌥↑ and ⌥↓ jump between groups, as in Claude Code's agent view.
        if flags == [.option], event.keyCode == 125 || event.keyCode == 126 {
            guard store.numberEntry == nil else { return true }
            if !store.keyboardMode { store.keyboardMode = true }
            keyboardSelectionLocation = NSEvent.mouseLocation
            store.selectGroup(forward: event.keyCode == 125)
            return true
        }
        guard flags.subtracting(.shift).isEmpty else { return false }
        if !store.keyboardMode { store.keyboardMode = true }
        keyboardSelectionLocation = NSEvent.mouseLocation
        if event.keyCode == 125 || event.keyCode == 126 {
            moveSelection(by: event.keyCode == 125 ? 1 : -1)
            return true
        }
        if let numberEntry = store.numberEntry {
            switch event.keyCode {
            case 53:
                setNumberEntry(nil)
                if store.selectedID == nil { store.selectedID = store.shownRows.first?.id }
            case 51, 117:
                setNumberEntry(String(numberEntry.dropLast()))
                store.selectedID = store.enteredSession?.id
            case 36, 76: openEnteredNumber()
            default:
                if let digit = event.characters { typeJumpDigit(digit) }
            }
            return true
        }
        let rows = store.shownRows
        switch event.keyCode {
        case 53:
            if store.isSearching { store.setQuery(nil) } else { close() }
        case 48:
            // Tab only switches between the tabs; groups are ⌥↑ and ⌥↓.
            let filters = SessionFilter.tabs
            if let current = filters.firstIndex(of: store.filter) {
                let step = flags.contains(.shift) ? -1 : 1
                store.setFilter(filters[(current + step + filters.count) % filters.count])
            }
        case 123, 124:
            return false
        case 36, 76:
            if let session = rows.first(where: { $0.id == store.selectedID })?.session { onOpen?(session) }
        case 51, 117:
            if store.isSearching { store.setQuery(String(store.query.dropLast())) }
            else if store.filter == .favorites { if !event.isARepeat { report(Self.favoritesKeepNotice) } }
            else if let target = store.removeTarget(allowSelection: true) { onHide?(target) }
        default:
            guard let key = event.characters, !key.isEmpty,
                  key.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(.punctuationCharacters)
                      .union(.symbols).union(.whitespaces).contains($0) }) else { return false }
            if !store.isSearching {
                switch key.lowercased() {
                case "/":
                    beginSearch()
                    return true
                case "d" where store.filter != .archive:
                    if !event.isARepeat { toggleDetails() }
                    return true
                case "0":
                    jumpByNumber()
                    return true
                case "e" where flags.contains(.shift):
                    // ⇧E clears every reply you have already read out of the Inbox.
                    if store.filter == .all, !event.isARepeat { onArchiveRead?() }
                    return true
                case "r" where store.filter == .archive:
                    if !event.isARepeat, let row = store.shownRows.first(where: { $0.id == store.selectedID }) {
                        onRestoreArchived?(row.session)
                    }
                    return true
                case "e", "l":
                    if store.filter != .archive, store.filter != .favorites, !event.isARepeat, let target = store.removeTarget(allowSelection: true) {
                        if key.lowercased() == "e" { onHide?(target) }
                        else { onLater?(target) }
                    }
                    return true
                case "f", "p":
                    if store.filter != .archive, !event.isARepeat, let target = store.removeTarget(allowSelection: true) {
                        togglePin(target)
                    }
                    return true
                case "h":
                    if store.filter != .archive, store.filter != .favorites, !event.isARepeat, store.removeTarget(allowSelection: true) != nil {
                        openPalette(choosingLater: true)
                    }
                    return true
                case "j", "k":
                    moveSelection(by: key.lowercased() == "j" ? 1 : -1)
                    return true
                case "z":
                    if !event.isARepeat { onUndo?() }
                    return true
                default:
                    if let position = Int(key), Shortcut.numbers.contains(position) {
                        if let session = store.session(in: position) { onOpen?(session) }
                        return true
                    }
                }
            }
            // Letters are commands, as in Superhuman; typing searches only after / or inside ⌘K.
            guard store.isSearching else { return true }
            store.setQuery(store.query + key)
        }
        return true
    }

    private func handlePaletteKey(_ event: NSEvent, flags: NSEvent.ModifierFlags) {
        if flags == [.command], event.charactersIgnoringModifiers?.lowercased() == "k" {
            closePalette()
            return
        }
        if flags == [.control], let key = event.charactersIgnoringModifiers?.lowercased(), key == "n" || key == "p" {
            store.movePaletteSelection(by: key == "n" ? 1 : -1)
            return
        }
        switch event.keyCode {
        case 53:
            closePalette()
        case 125, 126:
            store.movePaletteSelection(by: event.keyCode == 125 ? 1 : -1)
        case 36, 76:
            if let entry = store.selectedPaletteEntry { runPaletteEntry(entry) }
        case 51, 117:
            store.deleteInPalette()
            position()
        default:
            guard flags.subtracting(.shift).isEmpty, let text = event.characters, !text.isEmpty,
                  text.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(.punctuationCharacters)
                      .union(.symbols).union(.whitespaces).contains($0) }) else { return }
            store.typeInPalette(text)
            position()
        }
    }

    func runPaletteEntry(_ entry: PaletteEntry) {
        let target = store.paletteTarget?.session
        switch entry.action {
        case .chat(let id):
            closePalette()
            if let session = store.session(id: id) { onOpen?(session) }
        case .later(let date):
            closePalette()
            guard let target, store.deferSession(target, until: date) else { return }
            let when = date.map { " until " + SessionStore.describe($0, now: Date()) } ?? ""
            report("Moved “\(target.title)” to Later\(when)", undoable: true)
        case .command(.laterUntil):
            store.showLaterTimes()
            position()
        case .command(let command):
            closePalette()
            switch command {
            case .open: if let target { onOpen?(target) }
            case .archive: if let target { onHide?(target) }
            case .later: if let target { onLater?(target) }
            case .pin: if let target { togglePin(target) }
            case .read:
                if let target, let row = store.rows.first(where: { $0.id == target.id }) {
                    if row.needsReview { store.markRead(target) } else { store.markUnread(target) }
                }
            case .previews: store.setShowsAllSummaries(!store.showsAllSummaries)
            case .showAll: store.setFilter(.all)
            case .showFavorites: store.setFilter(.favorites)
            case .showLater: store.setFilter(.later)
            case .archiveList: showArchive()
            case .archiveRead: onArchiveRead?()
            case .restore: if let target { onRestoreArchived?(target) }
            case .jump: jumpByNumber()
            case .search: beginSearch()
            case .undo: onUndo?()
            case .settings: onShowSettings?()
            case .laterUntil: break
            }
        }
    }

    /// Favorites is a lasting list, so archive keys explain themselves there instead of archiving.
    static let favoritesKeepNotice = "Favorites keeps its chats. F removes one; archive from the Inbox."

    func togglePin(_ session: Session) {
        switch store.togglePin(session) {
        case true?: report("Added “\(session.title)” to Favorites")
        case false?: report("Removed “\(session.title)” from Favorites")
        case nil: report("Favorites holds up to \(SessionStore.maxPins) chats")
        }
    }

    /// The three dots: what there is beyond the list. Quit is here because Side Eye has no Dock icon, and
    /// its menu bar icon can sit hidden behind a notch or a menu bar manager.
    static func moreMenu(settings: @escaping () -> Void, welcome: @escaping () -> Void,
                         quit: @escaping () -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ClosureMenuItem("Settings…", run: settings))
        menu.addItem(ClosureMenuItem("Welcome to Side Eye…", run: welcome))
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Quit Side Eye", run: quit))
        return menu
    }

    private func showMoreMenu() {
        let menu = Self.moreMenu(settings: { [weak self] in self?.onShowSettings?() },
                                 welcome: { [weak self] in self?.onShowWelcome?() },
                                 quit: { [weak self] in self?.onQuit?() })
        // Under the pointer when a click opened it, else under the button at the sidebar's top right.
        let pointer = NSEvent.mouseLocation
        let place = sidebar.frame.contains(pointer) ? pointer
            : NSPoint(x: sidebar.frame.maxX - 36, y: sidebar.frame.maxY - OverlayMetrics.compactToolbarHeight)
        // After the click that opened it has finished, so the button does not stay pressed.
        DispatchQueue.main.async { [weak self] in self?.presentMenu(menu, place) }
    }

    private func moveSelection(by step: Int) {
        if store.numberEntry == nil {
            let ids = store.navigableIDs
            guard !ids.isEmpty else { return }
            let index = ids.firstIndex { $0 == store.selectedID }
                .map { max(0, min(ids.count - 1, $0 + step)) } ?? 0
            if store.selectedID != ids[index] { store.selectedID = ids[index] }
            return
        }
        let rows = store.shownRows
        guard !rows.isEmpty else { return }
        let jumping = store.numberEntry != nil
        let selection = jumping ? store.enteredSession?.id : store.selectedID
        let index = rows.firstIndex { $0.id == selection }
            .map { max(0, min(rows.count - 1, $0 + step)) } ?? 0
        if jumping { setNumberEntry(String(index + 1)) }
        if store.selectedID != rows[index].id { store.selectedID = rows[index].id }
    }

    private func installClickMonitors() {
        let events: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if mouseMonitor == nil {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
                MainActor.assumeIsolated { self?.closeOnOutsideClick() }
            }
        }
        if localMouseMonitor == nil {
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
                MainActor.assumeIsolated { self?.closeOnOutsideClick() }
                return event
            }
        }
        // Scrolling moves the rows under the pointer without moving the pointer.
        if scrollMonitor == nil {
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                MainActor.assumeIsolated { self?.pointer.scrolled() }
                return event
            }
        }
    }

    private func removeClickMonitors() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        mouseMonitor = nil
        localMouseMonitor = nil
        scrollMonitor = nil
    }

    private func closeOnOutsideClick() {
        guard followsPointer, menuTrackingDepth == 0 else { return }
        let pointer = NSEvent.mouseLocation
        if !sidebar.frame.contains(pointer), !rail.frame.contains(pointer) { close() }
    }

    private func attention(_ sessions: [Session]) {
        guard isEdgeVisible, !isShowing, !UserDefaults.standard.bool(forKey: "muteNudges") else { return }
        let all = sessions + queuedAttention
        var included = Set<String>()
        queuedAttention = all.filter { included.insert($0.id).inserted }.sorted {
            if $0.status != $1.status { return $0.status == .needsInput }
            return $0.updatedAt > $1.updatedAt
        }
        showNudge()
    }

    private func pruneAttention() {
        guard !queuedAttention.isEmpty else { return }
        let live = Dictionary(uniqueKeysWithValues: store.rows.map { ($0.id, $0.session) })
        let retained = queuedAttention.compactMap { prior -> Session? in
            guard let current = live[prior.id], current.hasSameActivity(as: prior),
                  store.isAttentionPending(for: current) else { return nil }
            return current
        }
        guard retained != queuedAttention else { return }
        if retained.isEmpty {
            hideNudge()
        } else {
            queuedAttention = retained
            renderNudge()
        }
    }

    private func showNudge(message: String? = nil) {
        guard isEdgeVisible, message != nil || !queuedAttention.isEmpty else { return }
        nudgeTask?.cancel()
        renderNudge(message: message)
        let duration = message != nil ? 4 : (queuedAttention.first?.status == .needsInput ? 12 : 9)
        nudgeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.hideNudge()
        }
    }

    private func renderNudge(message: String? = nil) {
        let session = message == nil ? queuedAttention.first : nil
        let view = NudgeView(session: session, additional: max(0, queuedAttention.count - 1), message: message,
                             open: { [weak self] in
            if let session { self?.onOpen?(session) }
        })
        presentedNudgeSize = OverlayMetrics.nudgeSize(for: session)
        if let content = nudge.contentView as? NSHostingView<NudgeView> {
            content.rootView = view
        } else {
            nudge.contentView = NSHostingView(rootView: view)
        }
        position()
        if !nudge.isVisible { nudge.orderFrontRegardless() }
    }

    private func hideNudge() {
        nudgeTask?.cancel()
        queuedAttention = []
        presentedNudgeSize = OverlayMetrics.nudgeSize
        nudge.orderOut(nil)
    }
}
