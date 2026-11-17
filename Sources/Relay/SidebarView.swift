import SwiftUI

enum OverlayMetrics {
    static let width: CGFloat = 402
    static let sidebarCornerRadius: CGFloat = 12
    static let railSize = NSSize(width: 38, height: 50)
    static let railPillRightInset: CGFloat = 8
    static let nudgeSize = NSSize(width: 334, height: 63)
    static let nudgeInset: CGFloat = 12
    static let nudgeSpacing: CGFloat = 8
    static let summaryFontSize: CGFloat = 13
    static let summaryLineHeight: CGFloat = 17
    static let nudgeSummaryLines = 5
    static let jumpSummaryLines = 5
    static let rowSummaryLines = 2
    static let sidebarInset: CGFloat = 1
    static let listInset: CGFloat = 5
    static let rowInset: CGFloat = 8
    static let rowSpacing: CGFloat = 7
    static let iconWidth: CGFloat = 18
    static let sourceIconSize: CGFloat = 13
    static let sourceIconSpacing: CGFloat = 5
    static let shortcutWidth: CGFloat = 24
    static let timestampWidth: CGFloat = 30
    static let rowMetadataHeight: CGFloat = 15
    static let compactRowHeight: CGFloat = 29
    static let groupHeaderHeight: CGFloat = 22
    /// Space that closes each group, so a group reads as one block and its header as its start.
    static let groupGap: CGFloat = 10
    static let allClearHeight: CGFloat = 24
    static let summaryBottomPadding: CGFloat = 6
    static let compactToolbarHeight: CGFloat = 38
    static let headerHeight: CGFloat = 43
    static let filterHeight: CGFloat = 31
    static let jumpBarHeight: CGFloat = 35
    static let footerHeight: CGFloat = 32
    static let emptyHeight: CGFloat = 88
    static let maxListHeight: CGFloat = 470
    static let maxBriefingListHeight: CGFloat = 560

    private static func summaryHeight(_ summary: String?, width: CGFloat, limit: Int) -> CGFloat {
        guard let summary, !summary.isEmpty else { return 0 }
        let font = NSFont.systemFont(ofSize: summaryFontSize)
        let bounds = (summary as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font])
        let naturalLineHeight = font.ascender - font.descender + font.leading
        let lines = max(1, min(CGFloat(limit), (bounds.height / naturalLineHeight).rounded()))
        return lines * summaryLineHeight
    }

    static func nudgeSize(for session: Session?) -> NSSize {
        let textWidth = nudgeSize.width - 2 * nudgeInset - iconWidth - nudgeSpacing
        let summary = summaryHeight(session?.stateSummary, width: textWidth - 2, limit: nudgeSummaryLines)
        guard summary > 0 else { return nudgeSize }
        return NSSize(width: nudgeSize.width, height: nudgeSize.height + summary)
    }

    static func jumpDetailHeight(for session: Session) -> CGFloat {
        let summary = summaryHeight(session.stateSummary, width: width - 2 * (sidebarInset + 12) - 2,
                                    limit: jumpSummaryLines)
        return summary == 0 ? 56 : 59 + summary
    }

    static func numberWidth(for rowCount: Int) -> CGFloat {
        max(shortcutWidth, 8 + 7 * CGFloat(String(rowCount).count))
    }

    static func compactSummaryInset(numberWidth: CGFloat) -> CGFloat {
        numberWidth + rowSpacing + sourceIconSize + sourceIconSpacing
    }

    /// The preview under a row. Previews are all or nothing: with them on, every row gets one, its
    /// summary or, until there is one, where the chat runs.
    @MainActor
    static func preview(for row: SessionRow, in store: SessionStore) -> RowPreview? {
        guard store.showsAllSummaries, store.numberEntry == nil, store.filter != .archive else { return nil }
        if let summary = row.session.stateSummary, !summary.isEmpty { return RowPreview(text: summary, isSummary: true) }
        let place = [row.session.source.name, row.session.detail].filter { !$0.isEmpty }.joined(separator: " · ")
        return RowPreview(text: place, isSummary: false)
    }

    @MainActor
    static func listHeight(for store: SessionStore) -> CGFloat {
        let items = store.sidebarItems
        guard !items.isEmpty else { return emptyHeight }
        let numberWidth = numberWidth(for: store.shownRows.count)
        let textWidth = width - 2 * (sidebarInset + listInset + rowInset) - compactSummaryInset(numberWidth: numberWidth)
        // A header that opens the list sits flush under the tabs.
        let topInset: CGFloat = if case .header = items.first { 0 } else { listInset }
        var height = topInset + listInset + CGFloat(items.count - 1)
        for (index, item) in items.enumerated() {
            switch item {
            case .allClear:
                height += allClearHeight
            case .header:
                height += groupHeaderHeight
                // The all-clear line sits directly on the first band; other groups are a gap apart.
                if index > 0, items[index - 1] != .allClear { height += groupGap + 1 }
            case .row(let row, _):
                height += compactRowHeight
                if let preview = preview(for: row, in: store) {
                    height += summaryHeight(preview.text, width: textWidth - 2,
                                            limit: preview.isSummary ? rowSummaryLines : 1) + summaryBottomPadding
                }
            }
        }
        return min(height, store.showsAllSummaries && store.numberEntry == nil ? maxBriefingListHeight : maxListHeight)
    }

    static let paletteRowHeight: CGFloat = 29
    static let paletteSectionHeight: CGFloat = 24

    @MainActor
    static func paletteListHeight(for store: SessionStore) -> CGFloat {
        let entries = store.paletteEntries
        guard !entries.isEmpty else { return emptyHeight }
        let sections = Set(entries.map(\.section)).count
        let height = 2 * listInset + CGFloat(entries.count) * paletteRowHeight + CGFloat(sections) * paletteSectionHeight
            + CGFloat(entries.count + sections - 1)
        return min(height, maxListHeight)
    }

    @MainActor
    static func sidebarHeight(for store: SessionStore) -> CGFloat {
        if store.palette != nil {
            return headerHeight + paletteListHeight(for: store) + footerHeight + 2
        }
        let list = listHeight(for: store)
        if store.numberEntry != nil {
            let detailHeight = store.enteredSession.map(jumpDetailHeight(for:)) ?? 0
            return headerHeight + jumpBarHeight + list + detailHeight + footerHeight + 2
        }
        if store.isSearching {
            let filters = store.filter == .archive ? 0 : filterHeight
            return headerHeight + filters + list + footerHeight + 2
        }
        return compactToolbarHeight + list + footerHeight + 2
    }
}

struct RowPreview: Equatable {
    let text: String
    let isSummary: Bool
}

/// One group of the list: its header, if it has one, and what sits under it.
struct ListBlock: Identifiable {
    let id: String
    var header: (group: SessionGroup, count: Int, read: Int)?
    var items: [SidebarItem] = []

    static func blocks(from items: [SidebarItem]) -> [ListBlock] {
        var blocks: [ListBlock] = []
        for item in items {
            if case .header(let group, let count, let read) = item {
                blocks.append(ListBlock(id: item.id, header: (group, count, read)))
                continue
            }
            if blocks.isEmpty { blocks.append(ListBlock(id: "top")) }
            blocks[blocks.count - 1].items.append(item)
        }
        return blocks
    }
}

struct OverlayColors {
    let dark: Bool

    var surface: Color { color(0x1D1D1F, 0xFCFCFB) }
    var primary: Color { color(0xF1F0EF, 0x232530) }
    var body: Color { color(0xCAC8C9, 0x444858) }
    var secondary: Color { color(0xA7A5AA, 0x606577) }
    var tertiary: Color { color(0x6F6D73, 0x9A9DA8) }
    var divider: Color { color(0x343437, 0xE4E5EA) }
    var selection: Color { color(0x2B2B30, 0xEDF0FC) }
    var accent: Color { color(0xADB6FB, 0x464EA8) }
    var inset: Color { color(0x242426, 0xF4F4F3) }
    var input: Color { color(0xF5C577, 0x704400) }
    var review: Color { color(0x9AD9AB, 0x1E5938) }
    var working: Color { color(0x9AD9F0, 0x145574) }
    var inputBadgeFill: Color { color(0x483420, 0xF8D68D) }
    var reviewBadgeFill: Color { color(0x274336, 0xCDEBD4) }
    var workingBadgeFill: Color { color(0x263E50, 0xCBE8F6) }

    private func color(_ darkHex: UInt32, _ lightHex: UInt32) -> Color {
        let hex = dark ? darkHex : lightHex
        return Color(red: Double((hex >> 16) & 0xFF) / 255,
                     green: Double((hex >> 8) & 0xFF) / 255,
                     blue: Double(hex & 0xFF) / 255)
    }
}

private enum SessionVisualState {
    case review, input, working, read, quiet, stale, unavailable

    init(row: SessionRow) {
        switch row.session.status {
        case .ready: self = row.needsReview ? .review : .read
        case .needsInput: self = .input
        case .working: self = .working
        case .idle: self = row.isStale ? .stale : .quiet
        case .unknown: self = .unavailable
        }
    }

    func tint(_ colors: OverlayColors) -> Color {
        switch self {
        case .review: colors.review
        case .input: colors.input
        case .working: colors.working
        case .read, .quiet, .stale, .unavailable: colors.secondary
        }
    }

    var isEmphasized: Bool {
        switch self {
        case .input, .review, .working: true
        case .read, .quiet, .stale, .unavailable: false
        }
    }
}

/// The one mark for a group of chats: on group headers, nudges and the all-clear line.
struct GroupGlyph: View {
    let group: SessionGroup
    let colors: OverlayColors

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turning = false

    /// Each status has one color, used by its glyph, its header and its unread dots.
    static func tint(_ group: SessionGroup, _ colors: OverlayColors) -> Color {
        switch group {
        case .needsInput: colors.input
        case .finished: colors.review
        case .working: colors.working
        case .quiet: colors.tertiary
        }
    }

    var body: some View {
        ZStack {
            switch group {
            case .needsInput:
                Circle().strokeBorder(lineWidth: 1.5)
                Capsule().frame(width: 1.5, height: 3.6).offset(y: -0.9)
                Circle().frame(width: 1.7, height: 1.7).offset(y: 2.6)
            case .finished:
                Circle().strokeBorder(lineWidth: 1.5)
                Circle().frame(width: 4.8, height: 4.8)
            case .working:
                // A slow turn says the agent is busy; Reduce Motion keeps it still.
                Circle().strokeBorder(lineWidth: 1.5)
                HalfDisc().frame(width: 6.8, height: 6.8)
                    .rotationEffect(.degrees(turning ? 360 : 0))
                    .animation(reduceMotion ? nil : .linear(duration: 2.4).repeatForever(autoreverses: false),
                               value: turning)
                    .onAppear { if !reduceMotion { turning = true } }
            case .quiet:
                Circle().inset(by: 0.75).stroke(style: StrokeStyle(lineWidth: 1.5, dash: [2.2, 2.2]))
            }
        }
        .foregroundStyle(Self.tint(group, colors))
        .frame(width: OverlayMetrics.sourceIconSize, height: OverlayMetrics.sourceIconSize)
        .accessibilityHidden(true)
    }
}

private struct AllClearGlyph: View {
    let colors: OverlayColors

    var body: some View {
        ZStack {
            Circle().strokeBorder(lineWidth: 1.5)
            CheckMark().stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        // Grey, not Review's green: the line reports an absence and belongs to no group.
        .foregroundStyle(colors.secondary)
        .frame(width: OverlayMetrics.sourceIconSize, height: OverlayMetrics.sourceIconSize)
        .accessibilityHidden(true)
    }
}

/// The right half of a disc: a chat that is part way through a turn.
private struct HalfDisc: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2,
                    startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
        path.closeSubpath()
        return path
    }
}

private struct CheckMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.32, y: rect.minY + rect.height * 0.52))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.45, y: rect.minY + rect.height * 0.64))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.69, y: rect.minY + rect.height * 0.38))
        return path
    }
}

private struct KeyCap: View {
    let key: String
    let colors: OverlayColors
    var prominent = false

    var body: some View {
        Text(key)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(prominent ? colors.primary : colors.secondary)
            .padding(.horizontal, 4)
            .frame(minWidth: 16, minHeight: 16)
            .background(prominent ? colors.inset : .clear, in: RoundedRectangle(cornerRadius: 4))
            .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(colors.divider) }
            .fixedSize()
            .accessibilityHidden(true)
    }
}

private extension SessionRow {
    var visualState: SessionVisualState { SessionVisualState(row: self) }
    var showsUnreadDot: Bool { isManuallyUnread && session.status != .ready }

    var stateTitle: String {
        if session.status == .unknown && session.detail == "Pinned link" { return "Pinned link" }
        if session.source == .instinct {
            if session.detail == "Waiting for reply" { return session.detail }
            if session.detail.contains("Full Disk Access") { return "Reply tracking off" }
        }
        return statusLabel
    }

    var stateDescription: String? {
        switch session.status {
        case .needsInput:
            return "Waiting for you to respond or approve."
        case .working:
            return "The source reports an active turn."
        case .ready:
            return needsReview ? "Queued for review." : "The latest update is marked as read."
        case .idle where session.source != .instinct:
            if isStale { return "No activity reported in the last eight hours." }
            return showsUnreadDot ? "Marked as unread." : "Relay sees no new update or input request."
        default:
            return nil
        }
    }

    private var shownCompletion: Date? {
        session.status == .ready ? session.completedAt : nil
    }

    var timestamp: Date? {
        if let shownCompletion { return shownCompletion }
        guard session.detail != "Pinned link" else { return nil }
        let activity = session.status == .idle
            ? max(session.updatedAt, session.completedAt ?? .distantPast)
            : session.updatedAt
        return activity > .distantPast ? activity : nil
    }

    var timestampDescription: String? {
        guard let timestamp else { return nil }
        let event = shownCompletion == nil ? "Last activity" : "Completed"
        return "\(event) \(timestamp.formatted(date: .abbreviated, time: .shortened))"
    }
}

private struct RowTimestamp: View {
    let date: Date
    let now: Date
    let colors: OverlayColors

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(colors.secondary)
            .lineLimit(1)
            .accessibilityHidden(true)
    }

    private var label: String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "now" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3_600)h" }
        if seconds < 31_536_000 { return "\(seconds / 86_400)d" }
        return "\(min(seconds / 31_536_000, 999))y"
    }
}

private struct RowNumber: View {
    let label: String
    let highlighted: Bool
    let colors: OverlayColors
    var boxed = false

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(highlighted ? colors.primary : colors.secondary)
            .lineLimit(1)
            .padding(.horizontal, 4)
            .frame(minWidth: OverlayMetrics.shortcutWidth, minHeight: 19)
            .background(boxed && highlighted ? colors.inset : .clear, in: RoundedRectangle(cornerRadius: 4))
            .overlay {
                if boxed && highlighted {
                    RoundedRectangle(cornerRadius: 4).strokeBorder(colors.divider)
                }
            }
    }
}

private struct RowMetadata: View {
    let row: SessionRow
    let colors: OverlayColors
    var showsStatus = true
    var now: Date = .now

    var body: some View {
        HStack(spacing: 6) {
            if showsStatus {
                Text(row.stateTitle)
                    .fontWeight(row.visualState.isEmphasized ? .semibold : .medium)
                    .foregroundStyle(row.visualState.tint(colors))
                separator
            }
            Text(row.session.source.name)
                .foregroundStyle(colors.secondary)
            if !showsStatus, let timestamp = row.timestamp {
                separator
                RowTimestamp(date: timestamp, now: now, colors: colors)
            }
            if row.showsUnreadDot {
                Circle()
                    .fill(colors.secondary)
                    .frame(width: 4, height: 4)
            }
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .frame(height: OverlayMetrics.rowMetadataHeight)
        .accessibilityHidden(true)
    }

    private var separator: some View {
        Circle().fill(colors.secondary).frame(width: 2, height: 2)
    }
}

private struct StateSummary: View {
    let summary: String
    let colors: OverlayColors
    let lineLimit: Int
    var heading: Text? = nil

    private var text: Text {
        guard let heading else { return Text(summary) }
        return summary.isEmpty ? heading : Text("\(heading) · \(summary)")
    }

    var body: some View {
        text
            .font(.system(size: OverlayMetrics.summaryFontSize))
            .foregroundStyle(colors.body)
            .lineSpacing(1)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct SidebarView: View {
    @ObservedObject var store: SessionStore
    let open: (Session) -> Void
    let hide: (Session) -> Void
    let showMenu: () -> Void
    let jump: () -> Void
    let search: () -> Void
    let toggleLater: (Session) -> Void
    let restoreArchived: (Session) -> Void
    var undo: () -> Void = {}
    var togglePin: (Session) -> Void = { _ in }
    var archiveRead: () -> Void = {}
    var runPalette: (PaletteEntry) -> Void = { _ in }
    var onHighlightRow: ((String) -> Void)? = nil
    var drawsSurface = true
    var presentation = 0

    @State private var hoveredRowID: String?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    private var colors: OverlayColors { OverlayColors(dark: scheme == .dark) }
    private var jumping: Bool { store.numberEntry != nil }
    private var browsingArchive: Bool { store.filter == .archive }
    private var showsToolbar: Bool { !jumping && !store.isSearching }

    var body: some View {
        TimelineView(.everyMinute) { _ in
            panel(now: .now)
        }
    }

    private func panel(now: Date) -> some View {
        let items = store.sidebarItems
        let rowCount = store.shownRows.count
        let entered = jumping ? store.enteredSession : nil
        let keyboardTarget = jumping ? entered?.id : (store.keyboardMode ? store.selectedID : nil)
        let shape = RoundedRectangle(cornerRadius: OverlayMetrics.sidebarCornerRadius, style: .continuous)
        return VStack(spacing: 0) {
            if let palette = store.palette {
                paletteHeader(palette)
                    .frame(height: OverlayMetrics.headerHeight)
                    .overlay(alignment: .bottom) { hairline }
                paletteList(palette)
            } else if showsToolbar {
                if browsingArchive {
                    header
                        .frame(height: OverlayMetrics.compactToolbarHeight)
                        .overlay(alignment: .bottom) { hairline }
                } else {
                    compactToolbar
                }
            } else {
                header
                    .frame(height: OverlayMetrics.headerHeight)
                    .overlay(alignment: .bottom) {
                        if browsingArchive && !jumping { hairline }
                    }
                if let number = store.numberEntry {
                    jumpBar(number, rowCount: rowCount, entered: entered)
                } else if !browsingArchive {
                    filters
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 9)
                        .frame(height: OverlayMetrics.filterHeight, alignment: .top)
                        .overlay(alignment: .bottom) { hairline }
                }
            }
            if store.palette != nil {
                EmptyView()
            } else if items.isEmpty {
                empty
            } else {
                sessionList(items, rowCount: rowCount, keyboardTarget: keyboardTarget, now: now)
                    .id(jumping)
            }
            if let row = store.shownRows.first(where: { $0.id == entered?.id }) {
                jumpDetail(row, now: now)
            }
            actionBar
                .frame(height: OverlayMetrics.footerHeight)
                .overlay(alignment: .top) { hairline }
        }
        .padding(OverlayMetrics.sidebarInset)
        .frame(width: OverlayMetrics.width)
        .background {
            if drawsSurface { shape.fill(colors.surface) }
            else { Color.black.opacity(1 / 255.0) }
        }
        .overlay {
            if drawsSurface { shape.strokeBorder(borderColor).allowsHitTesting(false) }
        }
        .clipShape(shape)
        .onChange(of: presentation) { hoveredRowID = nil }
        .onChange(of: store.filter) { hoveredRowID = nil }
        .foregroundStyle(colors.primary)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Relay chats")
    }

    private var borderColor: Color {
        contrast == .increased ? colors.secondary : colors.divider
    }

    private var header: some View {
        HStack(spacing: 8) {
            if browsingArchive && !jumping {
                headerButton("Back to Inbox", icon: "chevron.left") {
                    store.setQuery(nil)
                    store.setFilter(.all)
                }
            }
            if store.isSearching && !jumping {
                let placeholder = browsingArchive ? "Search archive" : "Search chats"
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(colors.secondary)
                    .accessibilityHidden(true)
                Text(store.query.isEmpty ? placeholder : store.query)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(store.query.isEmpty ? colors.secondary : colors.primary)
                    .lineLimit(1)
                    .accessibilityLabel(store.query.isEmpty ? placeholder : "Search \(store.query)")
            } else {
                Text(browsingArchive ? "Archive" : "Chats")
                    .font(.system(size: 14, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 0)
            if !jumping && store.isSearching {
                headerButton("Cancel search", icon: "xmark.circle") { store.setQuery(nil) }
            }
            if !jumping && !browsingArchive { summaryToggle }
            headerButton("Settings", icon: "ellipsis", action: showMenu)
        }
        .padding(.horizontal, browsingArchive && !store.isSearching && !jumping ? 9 : 13)
    }

    private var compactToolbar: some View {
        HStack(spacing: 5) {
            filters
            Spacer(minLength: 0)
            summaryToggle
            headerButton("Settings", icon: "ellipsis", action: showMenu)
        }
        .padding(.horizontal, 9)
        .frame(height: OverlayMetrics.compactToolbarHeight)
        .overlay(alignment: .bottom) { hairline }
    }

    private var summaryToggle: some View {
        let expanded = store.showsAllSummaries
        let title = expanded ? "Hide previews" : "Show previews"
        return headerButton(title, icon: expanded ? "list.bullet" : "list.bullet.rectangle",
                            help: store.isSearching ? title : "\(title) (D)") {
            store.setShowsAllSummaries(!expanded)
        }
        .accessibilityHint(store.isSearching ? "" : "Press D")
    }

    private func headerButton(_ title: String, icon: String, help: String? = nil,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(colors.secondary)
        .help(help ?? title)
        .accessibilityLabel(title)
    }

    private var filters: some View {
        HStack(spacing: 4) {
            ForEach(SessionFilter.tabs, id: \.self) { filter in
                let selected = filter == store.filter
                // Each tab says how many chats it lists.
                let count = filter == .all ? store.inboxCount : store.count(for: filter)
                Button { store.setFilter(filter) } label: {
                    HStack(spacing: 5) {
                        Text(filter.label)
                            .font(.system(size: 12, weight: selected ? .semibold : .medium))
                            .foregroundStyle(selected ? colors.accent : colors.body)
                        if count > 0 {
                            Text(String(count))
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                                .foregroundStyle(colors.secondary)
                        }
                    }
                    .padding(.horizontal, 7)
                    .frame(height: 23)
                    .background(selected ? colors.selection : .clear, in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Self.tabHelp(filter))
                .accessibilityLabel(filter.label)
                .accessibilityValue("\(count) \(count == 1 ? "chat" : "chats")")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private static func tabHelp(_ filter: SessionFilter) -> String {
        switch filter {
        case .favorites: "Chats you starred, in the order you added them (Tab)"
        case .later: "Chats you saved for later (Tab)"
        default: "What needs you, what to review and what's running (Tab)"
        }
    }

    private func jumpBar(_ number: String, rowCount: Int, entered: Session?) -> some View {
        HStack(spacing: 8) {
            Text("Jump to row")
                .font(.system(size: 12, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            if rowCount > 0 || !number.isEmpty {
                let range = rowCount == 1 ? "1" : "1 to \(rowCount)"
                RowNumber(label: number.isEmpty ? range : number, highlighted: true, colors: colors, boxed: true)
                    .accessibilityLabel(number.isEmpty ? "Available rows \(range)" : "Row " + number)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: OverlayMetrics.jumpBarHeight)
        .background(colors.inset, in: Rectangle())
        .overlay(alignment: .bottom) { hairline }
    }

    private func sessionList(_ items: [SidebarItem], rowCount: Int, keyboardTarget: String?,
                             now: Date) -> some View {
        let numberWidth = OverlayMetrics.numberWidth(for: rowCount)
        let nextID = store.nextActionID
        let blocks = ListBlock.blocks(from: items)
        let opensWithHeader = blocks.first?.header != nil
        return ScrollViewReader { proxy in
            ScrollView {
                // Each group is a section whose header stays pinned while you scroll through it.
                LazyVStack(spacing: 1, pinnedViews: [.sectionHeaders]) {
                    ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                        Section {
                            ForEach(block.items) { item in
                                switch item {
                                case .allClear:
                                    allClear
                                case .header:
                                    EmptyView()
                                case .row(let row, let position):
                                    sidebarRow(row, position: position, isNext: nextID == row.id,
                                               keyboardTarget: keyboardTarget, numberWidth: numberWidth, now: now)
                                }
                            }
                            if index < blocks.count - 1, block.items != [.allClear] {
                                Color.clear.frame(height: OverlayMetrics.groupGap).accessibilityHidden(true)
                            }
                        } header: {
                            if let header = block.header {
                                groupHeader(header.group, count: header.count, read: header.read)
                            }
                        }
                    }
                }
                .padding(.horizontal, OverlayMetrics.listInset)
                .padding(.top, opensWithHeader ? 0 : OverlayMetrics.listInset)
                .padding(.bottom, OverlayMetrics.listInset)
            }
            .scrollBounceBehavior(.basedOnSize)
            // A permanent scroll bar (mouse attached, or "always show") takes a gutter that cuts the group
            // bands short of the edge. Row numbers and pinned bands already say where you are.
            .scrollIndicators(.never)
            .onChange(of: keyboardTarget, initial: true) { _, id in
                if let id { proxy.scrollTo(id) }
            }
            .onChange(of: store.filter) {
                if let id = keyboardTarget ?? items.first?.id { proxy.scrollTo(id, anchor: .top) }
            }
            .onChange(of: presentation) {
                if let id = keyboardTarget ?? items.first?.id { proxy.scrollTo(id, anchor: .top) }
            }
            .onChange(of: store.showsAllSummaries) {
                if let keyboardTarget { proxy.scrollTo(keyboardTarget) }
            }
        }
    }

    private func sidebarRow(_ row: SessionRow, position: Int, isNext: Bool, keyboardTarget: String?,
                            numberWidth: CGFloat, now: Date) -> some View {
        let isMain = row.session.source == .grok && store.mainGrokIDs.contains(row.id)
        let keyboardSelected = keyboardTarget == row.id
        let pointerSelected = !jumping && !store.keyboardMode && store.selectedID == row.id
        let preview = OverlayMetrics.preview(for: row, in: store)
        let hasActions = !browsingArchive && !jumping && !store.isSearching && store.selectedID == row.id
        // Status shows once per view, always in words: the Inbox has its group bands; flat lists
        // (Favorites, Later and search results) write it on the row, since an icon alone needs a legend.
        let stateLabel = store.groupsRows || browsingArchive ? nil : row.shortState
        // In Later, a chat with a return time shows it beside an alarm. One saved without a time keeps
        // its usual timestamp, so no row is left without one.
        let returnLabel = store.filter == .later
            ? store.returnDate(for: row.id).map { Self.returnLabel($0, now: now) } : nil
        return SidebarRow(row: row, position: position, isNext: isNext, preview: preview, stateLabel: stateLabel,
                          returnLabel: returnLabel, isFavorite: store.isPinned(row.id),
                          canFavorite: canFavorite && !jumping,
                          toggleFavorite: { togglePin(row.session) },
                          jumping: jumping, searching: store.isSearching,
                          keyboardSelected: keyboardSelected, selected: keyboardSelected || pointerSelected,
                          showsMainChip: isMain && (jumping || store.showsAllSummaries),
                          isMain: isMain, colors: colors, now: now, numberWidth: numberWidth,
                          actionHelp: hasActions ? "E Archive · L \(laterActionLabel)" : nil,
                          activate: { open(row.session) },
                          hover: { hoverRow(row.id, entered: $0) })
            .contextMenu { rowMenu(row, isMain: isMain) }
            // No .id(row.id) here: ForEach already identifies rows by their ID, which is what scrollTo uses. A
            // second explicit ID made the lazy list keep old drawings of rows that moved to another section.
    }

    private func groupHeader(_ group: SessionGroup, count: Int, read: Int) -> some View {
        let tint = group == .quiet ? colors.secondary : GroupGlyph.tint(group, colors)
        // A header is a band across the whole list, starting in the number column rather than under the
        // titles, so it reads as the start of a group and not as another chat.
        return HStack(spacing: 7) {
            HStack(spacing: 7) {
                GroupGlyph(group: group, colors: colors)
                Text(group.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                // Needs you and Working count their rows. Review counts only what you have not read, and
                // says so, because read replies stay listed beneath it.
                if count > 0 {
                    Text(group == .finished ? "· \(count) unread" : String(count))
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(tint.opacity(0.62))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(read > 0 ? "\(group.label), \(count) unread, \(read) read" : "\(group.label), \(count)")
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if read > 0 && !jumping {
                Button(action: archiveRead) {
                    HStack(spacing: 5) {
                        Text("Archive \(read) read \(read == 1 ? "chat" : "chats")")
                        KeyCap(key: "⇧E", colors: colors)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(colors.secondary)
                    .frame(height: OverlayMetrics.groupHeaderHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Archive every chat you have already read (⇧E)")
                .accessibilityLabel("Archive \(read) read \(read == 1 ? "chat" : "chats")")
                .accessibilityHint("Shift E")
            }
        }
        .padding(.horizontal, OverlayMetrics.listInset + OverlayMetrics.rowInset)
        .frame(height: OverlayMetrics.groupHeaderHeight)
        .background {
            // Opaque, so the header can stay pinned over the rows scrolling beneath it.
            ZStack {
                colors.surface
                tint.opacity(colors.dark ? 0.13 : 0.075)
            }
            .overlay(alignment: .top) { colors.divider.frame(height: 1).opacity(0.7) }
            .overlay(alignment: .bottom) { colors.divider.frame(height: 1).opacity(0.7) }
        }
        .padding(.horizontal, -OverlayMetrics.listInset)
        .id(group.headerID)
    }

    /// A quiet line where the Needs you band would be. It is plain and grey because bold and colour
    /// mean something asks for you, and this says nothing does. It lines up with the bands' icons.
    private var allClear: some View {
        HStack(spacing: 7) {
            AllClearGlyph(colors: colors)
            Text("Nothing needs you")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(colors.secondary)
            Spacer(minLength: 0)
        }
        .padding(.leading, OverlayMetrics.rowInset)
        .frame(height: OverlayMetrics.allClearHeight)
        .accessibilityElement(children: .combine)
    }

    private func hoverRow(_ id: String, entered: Bool) {
        if entered {
            hoveredRowID = id
            if let onHighlightRow { onHighlightRow(id) }
            else if !store.keyboardMode { store.selectedID = id }
        } else if hoveredRowID == id {
            hoveredRowID = nil
        }
    }

    private var laterActionLabel: String { store.filter == .later ? "Move back" : "Later" }
    private var canFavorite: Bool { !browsingArchive }
    /// Later and Archive act on the Inbox. Favorites is a lasting list, so there you only open or unstar.
    private var triages: Bool { !browsingArchive && store.filter != .favorites }

    @ViewBuilder
    private func rowMenu(_ row: SessionRow, isMain: Bool) -> some View {
        Button("Open", systemImage: "arrow.up.forward") { open(row.session) }
        if browsingArchive {
            Button("Restore", systemImage: "arrow.uturn.backward") { restoreArchived(row.session) }
        } else {
            Button(row.needsReview ? "Mark as read" : "Mark as unread",
                   systemImage: row.needsReview ? "checkmark.circle" : "circlebadge") {
                if row.needsReview { store.markRead(row.session) }
                else { store.markUnread(row.session) }
            }
            if row.session.source == .grok {
                Button(isMain ? "Remove from main agents" : "Mark as main agent",
                       systemImage: isMain ? "star.slash" : "star") {
                    store.toggleGrokMain(id: row.id)
                }
            }
            if canFavorite {
                Button(store.isPinned(row.id) ? "Unfavorite" : "Favorite",
                       systemImage: store.isPinned(row.id) ? "star.slash" : "star") {
                    togglePin(row.session)
                }
            }
            if triages {
                Button(store.filter == .later ? "Move back" : "Move to Later",
                       systemImage: store.filter == .later ? "arrow.uturn.backward" : "clock") {
                    toggleLater(row.session)
                }
                Button("Archive", systemImage: "archivebox") { hide(row.session) }
            }
        }
    }

    private func jumpDetail(_ row: SessionRow, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(row.session.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(row.stateTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(row.visualState.tint(colors))
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(height: 18)
            if let summary = row.session.stateSummary, !summary.isEmpty {
                StateSummary(summary: summary, colors: colors, lineLimit: OverlayMetrics.jumpSummaryLines)
            }
            RowMetadata(row: row, colors: colors, showsStatus: false, now: now)
        }
        .padding(.horizontal, 12)
        .frame(height: OverlayMetrics.jumpDetailHeight(for: row.session))
        .background(colors.inset, in: Rectangle())
        .overlay(alignment: .top) { hairline }
        .help([row.session.title, row.timestampDescription, row.session.stateSummary]
            .compactMap { $0 }.joined(separator: "\n"))
        .accessibilityHidden(true)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(emptyTitle)
                .font(.system(size: 14, weight: .semibold))
            if let description = emptyDescription {
                Text(description)
                    .font(.system(size: 13))
                    .foregroundStyle(colors.body)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
    }

    private var emptyTitle: String {
        if store.isLoading { return "Finding chats…" }
        if !store.query.isEmpty { return "No chats match" }
        switch store.filter {
        case .all: return "Nothing in your inbox"
        case .favorites: return "No favorites yet"
        case .needsInput: return "Nothing needs you"
        case .toReview: return "Nothing to review"
        case .later: return "Nothing saved for later"
        case .archive: return store.missingArchiveCount > 0 ? "No archived chats available" : "No archived chats"
        }
    }

    private var emptyDescription: String? {
        if store.isLoading { return nil }
        if !store.query.isEmpty {
            if browsingArchive { return "Clear search to see the full archive." }
            return store.filter == .all ? "Clear search to see all chats." : "Try a different search or tab."
        }
        switch store.filter {
        case .all:
            return store.grokMainOnly && store.mainGrokIDs.isEmpty
                ? "Mark your main Grok agents in Settings."
                : "Chats land here when an agent needs you, finishes or starts work. Press / to find any other chat."
        case .favorites: return "Hover a chat and click its star, or select it and press F."
        case .needsInput: return "Questions and approvals will appear here."
        case .toReview: return "Unread updates will appear here."
        case .later: return "Press L on a chat to save it for later."
        case .archive:
            return store.missingArchiveCount > 0
                ? "Older archived chats appear when Relay finds them again."
                : "Chats you archive appear here."
        }
    }

    /// The bar under the list acts on the selected row, so the fastest path is always on screen.
    private var actionBar: some View {
        let target = jumping ? store.enteredSession?.id : store.selectedID
        let selected = store.shownRows.first { $0.id == target }
        return HStack(spacing: 12) {
            if store.palette != nil {
                keyHint("esc", "Close")
                Spacer(minLength: 0)
                if let entry = store.selectedPaletteEntry {
                    barButton(paletteVerb(entry), key: "↵", prominent: true, accessibilityHint: "Return") {
                        runPalette(entry)
                    }
                }
            } else if let notice = store.notice {
                Text(notice)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityAddTraits(.updatesFrequently)
                Spacer(minLength: 0)
                if store.noticeOffersUndo && store.canUndo && !jumping {
                    barButton("Undo", key: "Z", prominent: true, accessibilityHint: "Z", action: undo)
                }
            } else if jumping {
                if let prompt = jumpPrompt { Text(prompt) }
                Spacer(minLength: 0)
                keyHint("esc", "Cancel")
                if let selected {
                    barButton("Open", key: "↵", prominent: true, accessibilityHint: "Return") { open(selected.session) }
                }
            } else if store.isSearching {
                keyHint("esc", "Cancel")
                Spacer(minLength: 0)
                if let selected {
                    barButton("Open", key: "↵", prominent: true, accessibilityHint: "Return") { open(selected.session) }
                }
            } else {
                barButton("Search", key: "/", leadingKey: true,
                          accessibilityLabel: browsingArchive ? "Search archive" : "Search chats",
                          accessibilityHint: "Slash", action: search)
                    .help("Press / to search, or 0 to jump to a row number")
                Spacer(minLength: 0)
                if let selected {
                    // Only what this list is for: triage in the Inbox and Later, unfavoriting in
                    // Favorites, restoring in Archive. F and the hover star still favorite anywhere.
                    if browsingArchive {
                        barButton("Restore", key: "R", accessibilityHint: "R") { restoreArchived(selected.session) }
                    }
                    if store.filter == .favorites {
                        barButton(store.isPinned(selected.id) ? "Unfavorite" : "Favorite", key: "F",
                                  accessibilityHint: "F") { togglePin(selected.session) }
                    }
                    if triages {
                        barButton(laterActionLabel, key: "L", accessibilityHint: "L") { toggleLater(selected.session) }
                        barButton("Archive", key: "E", accessibilityHint: "E") { hide(selected.session) }
                    }
                    barButton("Open", key: "↵", prominent: true, accessibilityHint: "Return") { open(selected.session) }
                }
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(colors.secondary)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 12)
        .padding(.trailing, 10)
    }

    private var jumpPrompt: String? {
        let rows = store.shownRows
        if rows.isEmpty { return "No rows to open" }
        if store.numberEntry?.isEmpty == true { return "Type a number" }
        if store.enteredSession == nil { return rows.count == 1 ? "Choose row 1" : "Choose a row from 1 to \(rows.count)" }
        return nil
    }

    private func barButton(_ label: String, key: String, prominent: Bool = false, leadingKey: Bool = false,
                           accessibilityLabel: String? = nil, accessibilityHint: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if leadingKey { KeyCap(key: key, colors: colors, prominent: prominent) }
                Text(label)
                    .fontWeight(prominent ? .semibold : .medium)
                    .foregroundStyle(prominent ? colors.primary : colors.secondary)
                if !leadingKey { KeyCap(key: key, colors: colors, prominent: prominent) }
            }
            .fixedSize()
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel ?? label)
        .accessibilityHint(accessibilityHint)
    }

    private func keyHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            KeyCap(key: key, colors: colors)
            Text(label)
        }
        .fixedSize()
    }

    // MARK: ⌘K palette

    private func paletteHeader(_ palette: PaletteState) -> some View {
        let placeholder = palette.choosingLater ? "When should it come back?" : "Type a command or a chat"
        return HStack(spacing: 8) {
            Image(systemName: palette.choosingLater ? "alarm" : "command")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(colors.secondary)
                .accessibilityHidden(true)
            Text(palette.query.isEmpty ? placeholder : palette.query)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(palette.query.isEmpty ? colors.secondary : colors.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            KeyCap(key: "⌘K", colors: colors)
        }
        .padding(.horizontal, 13)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(palette.query.isEmpty ? placeholder : "Command \(palette.query)")
    }

    @ViewBuilder
    private func paletteList(_ palette: PaletteState) -> some View {
        let entries = store.paletteEntries
        if entries.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Nothing matches").font(.system(size: 14, weight: .semibold))
                Text("Try a chat’s name or a command like “archive”.")
                    .font(.system(size: 13))
                    .foregroundStyle(colors.body)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
        } else {
            let selectedID = entries.indices.contains(palette.index) ? entries[palette.index].id : nil
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            if index == 0 || entries[index - 1].section != entry.section {
                                Text(entry.section)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(colors.secondary)
                                    .lineLimit(1)
                                    .padding(.leading, OverlayMetrics.rowInset + OverlayMetrics.shortcutWidth
                                        + OverlayMetrics.rowSpacing)
                                    .frame(height: OverlayMetrics.paletteSectionHeight - 4, alignment: .bottom)
                                    .padding(.bottom, 4)
                                    .accessibilityAddTraits(.isHeader)
                            }
                            paletteRow(entry, selected: entry.id == selectedID, index: index)
                                .id(entry.id)
                        }
                    }
                    .padding(OverlayMetrics.listInset)
                }
                .scrollBounceBehavior(.basedOnSize)
                .onChange(of: selectedID, initial: true) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
    }

    private func paletteRow(_ entry: PaletteEntry, selected: Bool, index: Int) -> some View {
        Button { runPalette(entry) } label: {
            HStack(spacing: OverlayMetrics.rowSpacing) {
                // A chat reads as it does in the sidebar: its app's icon first, its status icon on the right.
                Group {
                    switch entry.icon {
                    case .symbol(let name):
                        Image(systemName: name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(colors.secondary)
                    case .source(let source):
                        SourceAppIcon(source: source, size: OverlayMetrics.sourceIconSize)
                            .frame(width: OverlayMetrics.sourceIconSize, height: OverlayMetrics.sourceIconSize)
                    }
                }
                .frame(width: OverlayMetrics.shortcutWidth)
                Text(entry.title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let state = entry.state {
                    Text(state)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(entry.group.map { GroupGlyph.tint($0, colors) } ?? colors.secondary)
                        .lineLimit(1)
                        .fixedSize()
                    Circle().fill(colors.secondary).frame(width: 2, height: 2)
                }
                if let detail = entry.detail {
                    Text(detail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(colors.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                if let key = entry.key { KeyCap(key: key, colors: colors) }
            }
            .padding(.horizontal, OverlayMetrics.rowInset)
            .frame(height: OverlayMetrics.paletteRowHeight)
            .background(selected ? colors.selection : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside, var state = store.palette, state.index != index {
                state.index = index
                store.palette = state
            }
        }
        .accessibilityLabel(entry.title)
        .accessibilityValue([entry.state, entry.detail, entry.key.map { "Shortcut \($0)" }].compactMap { $0 }
            .joined(separator: ", "))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func paletteVerb(_ entry: PaletteEntry) -> String {
        switch entry.action {
        case .chat, .command(.open): "Open"
        case .later: "Set"
        case .command(.laterUntil): "Choose"
        case .command: "Run"
        }
    }

    /// Short return time for a chat in Later: the hour today, otherwise the weekday.
    static func returnLabel(_ date: Date, now: Date) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? date.formatted(.dateTime.hour().minute())
            : date.formatted(.dateTime.weekday(.abbreviated))
    }

    private var hairline: some View {
        Rectangle().fill(borderColor).frame(height: 1)
    }
}

private struct SidebarRow: View {
    let row: SessionRow
    let position: Int
    let isNext: Bool
    let preview: RowPreview?
    let stateLabel: String?
    /// In Later, for a chat with a return time: when it comes back.
    let returnLabel: String?
    let isFavorite: Bool
    let canFavorite: Bool
    let toggleFavorite: () -> Void
    let jumping: Bool
    let searching: Bool
    let keyboardSelected: Bool
    let selected: Bool
    let showsMainChip: Bool
    let isMain: Bool
    let colors: OverlayColors
    let now: Date
    let numberWidth: CGFloat
    let actionHelp: String?
    let activate: () -> Void
    let hover: (Bool) -> Void

    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovered = false

    private var session: Session { row.session }
    private var showsStar: Bool { hovered && canFavorite }
    private var directShortcut: Bool { Shortcut.numbers.contains(position) }

    private var numberShortcut: String {
        directShortcut ? String(position) : "0, \(position), Return"
    }

    private var keyHelp: String? {
        if jumping { return "Enter \(position), then Return" }
        if searching { return keyboardSelected ? "Return to open" : nil }
        return numberShortcut
    }

    var body: some View {
        Button(action: activate) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: OverlayMetrics.rowSpacing) {
                    // Numbers are shortcuts, and digits type into a search, so search results carry none.
                    RowNumber(label: searching ? "" : String(position), highlighted: selected, colors: colors,
                              boxed: jumping)
                        .frame(width: numberWidth)
                        .accessibilityHidden(true)
                    title
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // Unread is a bold title and one dot. Its color says nothing about status; the group
                    // band or the status icon does that. Reading changes how the row looks, not where it is.
                    if row.needsReview {
                        Circle()
                            .fill(colors.accent)
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                    }
                    if let stateLabel {
                        Text(stateLabel)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(row.visualState.tint(colors))
                            .lineLimit(1)
                            .fixedSize()
                            .accessibilityHidden(true)
                    }
                    if !jumping {
                        ZStack(alignment: .trailing) {
                            if let returnLabel {
                                Label(returnLabel, systemImage: "alarm")
                                    .labelStyle(.titleAndIcon)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(colors.secondary)
                                    .fixedSize()
                            } else if let timestamp = row.timestamp {
                                RowTimestamp(date: timestamp, now: now, colors: colors)
                            }
                        }
                        .frame(minWidth: OverlayMetrics.timestampWidth, alignment: .trailing)
                        .opacity(showsStar ? 0 : 1)
                    }
                }
                .frame(height: OverlayMetrics.compactRowHeight)
                if let preview {
                    Group {
                        if preview.isSummary {
                            StateSummary(summary: preview.text, colors: colors, lineLimit: OverlayMetrics.rowSummaryLines)
                        } else {
                            Text(preview.text)
                                .font(.system(size: OverlayMetrics.summaryFontSize))
                                .foregroundStyle(colors.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .padding(.leading, OverlayMetrics.compactSummaryInset(numberWidth: numberWidth))
                    .padding(.bottom, OverlayMetrics.summaryBottomPadding)
                }
            }
            .padding(.horizontal, OverlayMetrics.rowInset)
            .background(selected ? colors.selection : .clear, in: RoundedRectangle(cornerRadius: 5))
            .overlay {
                if keyboardSelected && (jumping || contrast == .increased) {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(colors.secondary.opacity(contrast == .increased ? 1 : 0.48))
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            // Hovering a chat swaps its time for a star, so adding a favorite is one click away.
            if showsStar {
                Button(action: toggleFavorite) {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isFavorite ? colors.primary : colors.secondary)
                        .frame(width: OverlayMetrics.timestampWidth, height: OverlayMetrics.compactRowHeight,
                               alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, OverlayMetrics.rowInset)
                .help(isFavorite ? "Unfavorite (F)" : "Favorite (F)")
                .accessibilityLabel(isFavorite ? "Unfavorite" : "Favorite")
            }
        }
        .onHover { inside in
            hovered = inside
            hover(inside)
        }
        .help([session.title, session.source.name, session.detail, isMain ? "Main Grok agent" : nil, row.stateTitle,
               row.stateDescription, row.timestampDescription, session.stateSummary, keyHelp, actionHelp,
               keyboardSelected && !jumping ? (row.needsReview ? "⌘U Mark read" : "⌘U Mark unread") : nil]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"))
        .accessibilityLabel(session.title)
        .accessibilityValue([session.source.name, isMain ? "Main agent" : nil, row.stateTitle,
                             isNext ? "Next to act on" : nil, row.needsReview ? "Unread" : nil,
                             row.timestampDescription, session.stateSummary,
                             jumping || searching ? "Row \(position)" : "Shortcut \(numberShortcut)"]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var title: some View {
        HStack(spacing: OverlayMetrics.sourceIconSpacing) {
            SourceAppIcon(source: session.source, size: OverlayMetrics.sourceIconSize)
                .frame(width: OverlayMetrics.sourceIconSize, height: OverlayMetrics.sourceIconSize)
                .accessibilityHidden(true)
            Text(session.title)
                // Two styles only: bold, with a dot, when there is something new for you; plain otherwise.
                .font(.system(size: 14, weight: row.needsReview ? .semibold : .regular))
                .foregroundStyle(row.needsReview ? colors.primary : colors.body)
                .lineLimit(1)
                .truncationMode(.tail)
            if showsMainChip {
                Text("Main")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(colors.secondary)
                    .padding(.horizontal, 4)
                    .frame(height: 15)
                    .background(colors.inset, in: RoundedRectangle(cornerRadius: 4))
                    .fixedSize()
                    .accessibilityHidden(true)
            }
        }
    }
}

enum RailPhase: Equatable {
    case idle, pressed, dragging
}

@MainActor
final class RailMotion: ObservableObject {
    @Published var phase: RailPhase = .idle
    @Published var showsPill = true
}

struct RailView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var motion: RailMotion = RailMotion()
    let show: () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var animation: Animation? {
        guard !reduceMotion else { return nil }
        if motion.phase == .pressed { return .easeOut(duration: 0.09) }
        return .spring(response: 0.28, dampingFraction: 0.65)
    }

    static func pillSize(counted: Bool, phase: RailPhase) -> CGSize {
        switch phase {
        case .idle: counted ? CGSize(width: 22, height: 34) : CGSize(width: 7, height: 24)
        case .pressed: counted ? CGSize(width: 26, height: 38) : CGSize(width: 15, height: 31)
        case .dragging: counted ? CGSize(width: 30, height: 44) : CGSize(width: 18, height: 36)
        }
    }

    private func activity(input: Int, review: Int) -> String {
        let inputDescription = "\(input) \(input == 1 ? "needs" : "need") input"
        if input > 0 && review > 0 { return "\(inputDescription), \(review) to review" }
        if input > 0 { return inputDescription }
        if review > 0 { return "\(review) to review" }
        if store.workingCount > 0 { return "No sessions need attention, \(store.workingCount) working" }
        return "No sessions need attention"
    }

    var body: some View {
        let colors = OverlayColors(dark: scheme == .dark)
        let shape = Capsule()
        let input = store.count(for: .needsInput)
        let total = store.attentionCount
        let counted = total > 0
        let phase = motion.phase
        let held = phase != .idle
        let size = Self.pillSize(counted: counted, phase: phase)
        let accent = input > 0 ? colors.input : colors.review
        let edgeOpacity = held ? 0.66 : 0.28
        let quietOpacity = held ? 0.84 : 0.55
        let glowOpacity = phase == .dragging ? 0.33 : (held ? 0.22 : 0)
        return Button(action: show) {
            Group {
                if counted {
                    Text(total > 99 ? "99+" : String(total))
                        .font(.system(size: total > 99 ? 10 : 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(accent)
                        .frame(width: size.width, height: size.height)
                        .background(held ? colors.selection : colors.surface, in: shape)
                        .overlay {
                            shape.strokeBorder(colors.secondary.opacity(contrast == .increased ? 1 : edgeOpacity))
                        }
                } else {
                    shape
                        .fill(colors.secondary.opacity(contrast == .increased ? 1 : quietOpacity))
                        .frame(width: size.width, height: size.height)
                }
            }
            .shadow(color: (counted ? accent : colors.secondary).opacity(glowOpacity),
                    radius: 3, y: phase == .dragging ? 2 : 0)
            .padding(.trailing, OverlayMetrics.railPillRightInset)
            .frame(width: OverlayMetrics.railSize.width, height: OverlayMetrics.railSize.height,
                   alignment: .trailing)
            .animation(animation, value: phase)
            .opacity(motion.showsPill ? 1 : 0)
            .background(Color.black.opacity(motion.showsPill ? 0 : 1 / 255.0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show Relay sessions")
        .accessibilityValue(activity(input: input, review: total - input))
    }
}

struct NudgeView: View {
    let session: Session?
    let additional: Int
    let message: String?
    let open: () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    private var colors: OverlayColors { OverlayColors(dark: scheme == .dark) }
    private var row: SessionRow? { session.map { SessionRow(session: $0, needsReview: true) } }

    private var details: String {
        [session?.source.name, row?.stateTitle, session?.stateSummary,
         additional > 0 ? "\(additional) more to review" : nil]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    var body: some View {
        if let session {
            Button(action: open) { content }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(session.title)")
                .accessibilityValue(details)
                .help(details)
        } else {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(message ?? "Relay")
        }
    }

    private var content: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        let size = OverlayMetrics.nudgeSize(for: session)
        return HStack(alignment: session == nil ? .center : .top, spacing: OverlayMetrics.nudgeSpacing) {
            if let row {
                GroupGlyph(group: SessionGroup(row), colors: colors)
                    .frame(width: OverlayMetrics.iconWidth, height: 20)
            } else {
                Image(systemName: "info.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(colors.secondary)
                    .frame(width: OverlayMetrics.iconWidth)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(message ?? session?.title ?? "Relay")
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(session == nil ? 2 : 1)
                    Spacer(minLength: 0)
                    if additional > 0 {
                        Text("+\(additional)")
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(colors.secondary)
                    }
                    if session != nil {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(colors.secondary)
                    }
                }
                .frame(minHeight: 20)
                if let summary = session?.stateSummary, !summary.isEmpty {
                    StateSummary(summary: summary, colors: colors, lineLimit: OverlayMetrics.nudgeSummaryLines)
                }
                if let row { RowMetadata(row: row, colors: colors) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, OverlayMetrics.nudgeInset)
        .frame(width: size.width, height: size.height)
        .foregroundStyle(colors.primary)
        .background(colors.surface, in: shape)
        .overlay { shape.strokeBorder(contrast == .increased ? colors.secondary : colors.divider) }
        .contentShape(Rectangle())
    }
}
