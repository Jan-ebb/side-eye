import SwiftUI

enum OverlayMetrics {
    static let width: CGFloat = 380
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
    static let sidebarInset: CGFloat = 1
    static let listInset: CGFloat = 5
    static let rowInset: CGFloat = 8
    static let rowSpacing: CGFloat = 7
    static let iconWidth: CGFloat = 18
    static let shortcutWidth: CGFloat = 24
    static let timestampWidth: CGFloat = 30
    static let briefingTailWidth: CGFloat = 42
    static let briefingRowPadding: CGFloat = 9
    static let briefingTitleHeight: CGFloat = 18
    static let rowMetadataHeight: CGFloat = 15
    static let briefingLineGap: CGFloat = 2
    static let briefingViewportRows = 6
    static let compactRowHeight: CGFloat = 27
    static let compactToolbarHeight: CGFloat = 38
    static let compactDetailHeight: CGFloat = 72
    static let headerHeight: CGFloat = 43
    static let filterHeight: CGFloat = 31
    static let jumpBarHeight: CGFloat = 35
    static let footerHeight: CGFloat = 32
    static let frameChrome = headerHeight + filterHeight + footerHeight + 2
    static let emptyHeight: CGFloat = 88

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

    private static func briefingRowHeight(for session: Session, tailWidth: CGFloat) -> CGFloat {
        let textWidth = width - 2 * (sidebarInset + listInset + rowInset + rowSpacing) - iconWidth - tailWidth
        let summary = summaryHeight(session.stateSummary, width: textWidth - 2, limit: 2)
        let chrome = briefingTitleHeight + rowMetadataHeight + briefingLineGap + 2 * briefingRowPadding
        return summary == 0 ? chrome : chrome + briefingLineGap + summary
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

    private static func briefingListHeight(for rows: [SessionRow]) -> CGFloat {
        guard !rows.isEmpty else { return emptyHeight }
        let tailWidth = max(briefingTailWidth, numberWidth(for: rows.count))
        return rows.prefix(briefingViewportRows).reduce(11) {
            $0 + briefingRowHeight(for: $1.session, tailWidth: tailWidth)
        }
    }

    static func numberWidth(for rowCount: Int) -> CGFloat {
        max(shortcutWidth, 8 + 7 * CGFloat(String(rowCount).count))
    }

    private static func compactListHeight(for count: Int) -> CGFloat {
        count == 0 ? emptyHeight : 10 + CGFloat(count) * compactRowHeight + CGFloat(count - 1)
    }

    @MainActor
    static func sidebarHeight(for store: SessionStore) -> CGFloat {
        let rows = store.shownRows
        if store.numberEntry != nil {
            let detailHeight = store.enteredSession.map(jumpDetailHeight(for:)) ?? 0
            return headerHeight + jumpBarHeight + compactListHeight(for: min(rows.count, 18))
                + detailHeight + footerHeight + 2
        }
        if store.showsAllSummaries { return frameChrome + briefingListHeight(for: rows) }
        let chrome = store.query.isEmpty ? compactToolbarHeight + footerHeight + 2 : frameChrome
        return chrome + compactListHeight(for: min(rows.count, 12)) + (rows.isEmpty ? 0 : compactDetailHeight)
    }
}

struct OverlayColors {
    let dark: Bool

    var surface: Color { color(0x1D1D1F, 0xFAF9F8) }
    var primary: Color { color(0xF1F0EF, 0x222224) }
    var body: Color { color(0xCAC8C9, 0x444448) }
    var secondary: Color { color(0xA7A5AA, 0x5D5C62) }
    var divider: Color { color(0x343437, 0xDEDCDB) }
    var selection: Color { color(0x2B2B30, 0xEAE9ED) }
    var inset: Color { color(0x242426, 0xF1F0EF) }
    var input: Color { color(0xE6B571, 0x81500F) }
    var review: Color { color(0x89D1A9, 0x266147) }
    var working: Color { color(0x8CB7EF, 0x2F5987) }

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
}

private struct SessionStateIcon: View {
    let state: SessionVisualState
    let colors: OverlayColors

    var body: some View {
        Group {
            switch state {
            case .review:
                Circle()
                    .strokeBorder(lineWidth: 1)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().frame(width: 4, height: 4))
            case .input:
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(lineWidth: 1)
                    .frame(width: 12, height: 12)
                    .overlay(Text("!").font(.system(size: 9, weight: .bold)))
            case .working:
                symbol("arrow.clockwise")
            case .read:
                symbol("checkmark")
            case .quiet:
                symbol("minus")
            case .stale:
                symbol("clock")
            case .unavailable:
                symbol("questionmark.circle")
            }
        }
        .foregroundStyle(state.tint(colors))
        .frame(width: OverlayMetrics.iconWidth, height: 18)
        .accessibilityHidden(true)
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 11, weight: .medium))
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
        case .ready:
            return needsReview ? "Queued for review." : "The latest update is marked as read."
        case .idle where session.source != .instinct:
            if isStale { return "No activity reported in the last eight hours." }
            return showsUnreadDot ? "Marked as unread." : "Relay sees no new update or input request."
        default:
            return nil
        }
    }

    var timestamp: Date? {
        if let completedAt = session.completedAt { return completedAt }
        if session.updatedAt > .distantPast, session.detail != "Pinned link" { return session.updatedAt }
        return nil
    }

    var timestampDescription: String? {
        guard let timestamp else { return nil }
        let event = session.completedAt == nil ? "Last activity" : "Completed"
        return "\(event) \(timestamp.formatted(date: .abbreviated, time: .shortened))"
    }
}

private struct RowTimestamp: View {
    let date: Date
    let now: Date
    let colors: OverlayColors

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
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
    var outlined = false

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(highlighted ? colors.primary : colors.secondary)
            .lineLimit(1)
            .padding(.horizontal, 4)
            .frame(minWidth: OverlayMetrics.shortcutWidth, minHeight: 19)
            .background(highlighted ? colors.inset : .clear, in: RoundedRectangle(cornerRadius: 4))
            .overlay {
                if highlighted || outlined {
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
                    .fontWeight(.medium)
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

    var body: some View {
        Text(summary)
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
    var onHighlightRow: ((String) -> Void)? = nil
    var drawsSurface = true
    var presentation = 0

    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    private var colors: OverlayColors { OverlayColors(dark: scheme == .dark) }
    private var jumping: Bool { store.numberEntry != nil }
    private var compact: Bool { !jumping && !store.showsAllSummaries }

    var body: some View {
        TimelineView(.everyMinute) { _ in
            panel(now: .now)
        }
    }

    private func panel(now: Date) -> some View {
        let rows = store.shownRows
        let entered = jumping ? store.enteredSession : nil
        let keyboardTarget = jumping ? entered?.id : (store.keyboardMode ? store.selectedID : nil)
        let preview = compact ? rows.first { $0.id == store.selectedID } ?? rows.first : nil
        let shape = RoundedRectangle(cornerRadius: OverlayMetrics.sidebarCornerRadius, style: .continuous)
        return VStack(spacing: 0) {
            if compact && store.query.isEmpty {
                compactToolbar
            } else {
                header
                    .frame(height: OverlayMetrics.headerHeight)
                if let number = store.numberEntry {
                    jumpBar(number, rowCount: rows.count, entered: entered)
                } else {
                    filters
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 9)
                        .frame(height: OverlayMetrics.filterHeight, alignment: .top)
                        .overlay(alignment: .bottom) { hairline }
                }
            }
            if rows.isEmpty {
                empty
            } else {
                sessionList(rows, keyboardTarget: keyboardTarget, previewID: preview?.id, now: now)
                    .id(jumping)
            }
            if let row = preview ?? rows.first(where: { $0.id == entered?.id }) {
                sessionDetail(row, now: now)
            }
            footer(rows)
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
        .foregroundStyle(colors.primary)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Relay sessions")
    }

    private var borderColor: Color {
        contrast == .increased ? colors.secondary : colors.divider
    }

    private var header: some View {
        HStack(spacing: 8) {
            if !store.query.isEmpty && !jumping {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(colors.secondary)
                    .accessibilityHidden(true)
                Text(store.query)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                    .accessibilityLabel("Search " + store.query)
            } else {
                Text("Sessions")
                    .font(.system(size: 15, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 0)
            if !jumping && !store.query.isEmpty {
                headerButton("Clear search", icon: "xmark.circle") { store.setQuery("") }
            }
            if !jumping { summaryToggle }
            headerButton("Settings", icon: "ellipsis", action: showMenu)
        }
        .padding(.horizontal, 13)
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
        let title = expanded ? "Show compact list" : "Show Briefing"
        return headerButton(title, icon: expanded ? "list.bullet" : "list.bullet.rectangle",
                            help: "\(title) (⌃⌥D)") {
            store.setShowsAllSummaries(!expanded)
        }
        .accessibilityHint("Control Option D")
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
            ForEach(SessionFilter.allCases, id: \.self) { filter in
                let selected = filter == store.filter
                let count = store.count(for: filter)
                Button { store.setFilter(filter) } label: {
                    HStack(spacing: 5) {
                        Text(filter.label)
                            .font(.system(size: 11, weight: selected ? .semibold : .medium))
                            .foregroundStyle(selected ? colors.primary : colors.body)
                        Text(String(count))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(filterCountColor(filter, count: count))
                    }
                    .padding(.horizontal, 7)
                    .frame(height: 23)
                    .background(selected ? colors.selection : .clear, in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(filter.label)
                .accessibilityValue("\(count) \(count == 1 ? "session" : "sessions")")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private func filterCountColor(_ filter: SessionFilter, count: Int) -> Color {
        if count == 0 { return colors.secondary }
        switch filter {
        case .all: return colors.secondary
        case .needsInput: return colors.input
        case .toReview: return colors.review
        }
    }

    private func jumpBar(_ number: String, rowCount: Int, entered: Session?) -> some View {
        HStack(spacing: 8) {
            Text("Jump to row")
                .font(.system(size: 12, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            if rowCount > 0 || !number.isEmpty {
                let range = rowCount == 1 ? "1" : "1 to \(rowCount)"
                RowNumber(label: number.isEmpty ? range : number, highlighted: true, colors: colors)
                    .accessibilityLabel(number.isEmpty ? "Available rows \(range)" : "Row " + number)
            }
            Spacer(minLength: 0)
            if entered != nil { hint("↵", "Open") }
        }
        .padding(.horizontal, 12)
        .frame(height: OverlayMetrics.jumpBarHeight)
        .background(colors.inset, in: Rectangle())
        .overlay(alignment: .bottom) { hairline }
    }

    private func sessionList(_ rows: [SessionRow], keyboardTarget: String?, previewID: String?, now: Date) -> some View {
        let numberWidth = OverlayMetrics.numberWidth(for: rows.count)
        let compactRows = compact || jumping
        let nextID = store.nextActionID
        let latestID = store.latestReplyID
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: compactRows ? 1 : 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        let isMain = row.session.source == .grok && store.mainGrokIDs.contains(row.id)
                        SidebarRow(row: row, position: index + 1, compact: compactRows, jumping: jumping,
                                   keyboardMode: store.keyboardMode,
                                   keyboardSelected: keyboardTarget == row.id,
                                   previewSelected: previewID == row.id,
                                   isNext: nextID == row.id, isLatest: latestID == row.id,
                                   isMain: isMain, colors: colors, now: now, numberWidth: numberWidth,
                                   activate: { open(row.session) },
                                   highlight: {
                                       if let onHighlightRow { onHighlightRow(row.id) }
                                       else if !store.keyboardMode { store.selectedID = row.id }
                                   })
                        .contextMenu { rowMenu(row, isMain: isMain) }
                        .id(row.id)
                    }
                }
                .padding(.horizontal, OverlayMetrics.listInset)
                .padding(.top, 5)
                .padding(.bottom, compactRows ? 5 : 6)
            }
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: keyboardTarget, initial: true) { _, id in
                if let id { proxy.scrollTo(id) }
            }
            .onChange(of: store.filter) {
                if let id = keyboardTarget ?? rows.first?.id { proxy.scrollTo(id, anchor: .top) }
            }
            .onChange(of: presentation) {
                if let id = keyboardTarget ?? rows.first?.id { proxy.scrollTo(id, anchor: .top) }
            }
            .onChange(of: compactRows) {
                if let keyboardTarget { proxy.scrollTo(keyboardTarget) }
            }
        }
    }

    @ViewBuilder
    private func rowMenu(_ row: SessionRow, isMain: Bool) -> some View {
        Button("Open", systemImage: "arrow.up.forward") { open(row.session) }
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
        Button("Archive session", systemImage: "archivebox") { hide(row.session) }
    }

    private func sessionDetail(_ row: SessionRow, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(row.session.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .accessibilityHidden(compact)
                Spacer(minLength: 0)
                Text(compact ? row.session.source.name : row.stateTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(compact ? colors.secondary : row.visualState.tint(colors))
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityHidden(compact)
                if compact { detailAction(for: row) }
            }
            .frame(height: 18)
            if let summary = row.session.stateSummary, !summary.isEmpty {
                StateSummary(summary: summary, colors: colors, lineLimit: compact ? 2 : OverlayMetrics.jumpSummaryLines)
                    .accessibilityHidden(compact)
            } else if compact {
                Text("No summary available")
                    .font(.system(size: 13))
                    .foregroundStyle(colors.secondary)
                    .accessibilityHidden(true)
            }
            if !compact {
                RowMetadata(row: row, colors: colors, showsStatus: false, now: now)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, compact ? 8 : 0)
        .frame(height: compact ? OverlayMetrics.compactDetailHeight : OverlayMetrics.jumpDetailHeight(for: row.session),
               alignment: compact ? .topLeading : .center)
        .background(colors.inset, in: Rectangle())
        .overlay(alignment: .top) { hairline }
        .help([row.session.title, row.timestampDescription, row.session.stateSummary]
            .compactMap { $0 }.joined(separator: "\n"))
        .accessibilityHidden(!compact)
    }

    private func detailAction(for row: SessionRow) -> some View {
        let action: String
        switch row.visualState {
        case .input: action = "Respond"
        case .review: action = "Review reply"
        default: action = row.needsReview ? "Review update" : "Open chat"
        }
        return Button { open(row.session) } label: {
            HStack(spacing: 4) {
                Text(action)
                    .font(.system(size: 11, weight: .semibold))
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8, weight: .semibold))
            }
            .fixedSize()
            .frame(minHeight: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(row.session.status.requestsAttention && row.visualState != .read
                         ? row.visualState.tint(colors) : colors.primary)
        .accessibilityLabel(action)
        .accessibilityHint("Opens \(row.session.title)")
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
        if store.isLoading { return "Finding sessions…" }
        if !store.query.isEmpty { return "No sessions match" }
        switch store.filter {
        case .all: return "No active sessions"
        case .needsInput: return "Nothing needs input"
        case .toReview: return "Nothing to review"
        }
    }

    private var emptyDescription: String? {
        if store.isLoading { return nil }
        if !store.query.isEmpty {
            return store.filter == .all ? "Clear search to see all sessions." : "Try a different search or filter."
        }
        switch store.filter {
        case .all:
            return store.grokMainOnly && store.mainGrokIDs.isEmpty
                ? "Mark your main Grok agents in Settings."
                : "Open a chat to see it here."
        case .needsInput: return "Questions and approvals will appear here."
        case .toReview: return "Unread updates will appear here."
        }
    }

    private func footer(_ rows: [SessionRow]) -> some View {
        HStack(spacing: 9) {
            if let notice = store.notice {
                Text(notice).lineLimit(1).accessibilityAddTraits(.updatesFrequently)
            } else if let number = store.numberEntry {
                if rows.isEmpty {
                    Text("No rows to open")
                } else if number.isEmpty {
                    Text("Type a number")
                } else if store.enteredSession == nil {
                    Text(rows.count == 1 ? "Choose row 1" : "Choose a row from 1 to \(rows.count)")
                }
                Spacer(minLength: 0)
                hint("Esc", "Cancel")
            } else {
                if !rows.isEmpty {
                    hint("↑↓", "Select")
                    hint("↵", "Open")
                } else if store.query.isEmpty {
                    hint("⌃⌥↵", "Review")
                }
                Spacer(minLength: 0)
                if store.query.isEmpty {
                    hint("⌃⌥A", "Archive")
                } else {
                    hint("Esc", "Clear")
                }
                hint("⌃⌥D", compact ? "Briefing" : "Compact")
                if !rows.isEmpty { hint("⌃⌥0", "Jump") }
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(colors.secondary)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
    }

    private func hint(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(keys).font(.system(size: 11, weight: .medium, design: .monospaced))
            Text(label).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(colors.secondary)
        .fixedSize()
    }

    private var hairline: some View {
        Rectangle().fill(borderColor).frame(height: 1)
    }
}

private struct SidebarRow: View {
    let row: SessionRow
    let position: Int
    let compact: Bool
    let jumping: Bool
    let keyboardMode: Bool
    let keyboardSelected: Bool
    let previewSelected: Bool
    let isNext: Bool
    let isLatest: Bool
    let isMain: Bool
    let colors: OverlayColors
    let now: Date
    let numberWidth: CGFloat
    let activate: () -> Void
    let highlight: () -> Void

    @State private var hovered = false
    @Environment(\.colorSchemeContrast) private var contrast

    private var session: Session { row.session }
    private var selected: Bool { keyboardSelected || previewSelected || (!compact && !keyboardMode && hovered) }
    private var directShortcut: Bool { Shortcut.numbers.contains(position) }
    private var cue: String? {
        if !compact { return isNext ? "Up next" : nil }
        if isNext { return isLatest ? "Next · Latest" : "Next" }
        return isLatest ? "Latest" : nil
    }

    private var cueDescription: String? {
        if isNext { return isLatest ? "Next to act on, latest reply" : "Next to act on" }
        return isLatest ? "Latest reply" : nil
    }

    private var keyHelp: String {
        if jumping || !directShortcut { return "⌃⌥0, \(position), Return" }
        return "⌃⌥\(position)"
    }

    var body: some View {
        Button(action: activate) {
            Group {
                if compact { compactContent }
                else { briefingContent }
            }
            .padding(.horizontal, OverlayMetrics.rowInset)
            .padding(.vertical, compact ? 0 : OverlayMetrics.briefingRowPadding)
            .frame(height: compact ? OverlayMetrics.compactRowHeight : nil)
            .background {
                if compact {
                    RoundedRectangle(cornerRadius: 5).fill(selected ? colors.selection : .clear)
                } else {
                    Rectangle().fill(briefingBackground)
                }
            }
            .overlay(alignment: .bottom) {
                if !compact {
                    Rectangle()
                        .fill(contrast == .increased ? colors.secondary : colors.divider)
                        .frame(height: 1)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if keyboardSelected {
                    RoundedRectangle(cornerRadius: compact ? 5 : 3)
                        .strokeBorder(colors.secondary.opacity(contrast == .increased ? 1 : 0.48))
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isInside in
            hovered = isInside
            if isInside { highlight() }
        }
        .help([session.title, session.detail, isMain ? "Main Grok agent" : nil, row.stateTitle,
               cueDescription, row.stateDescription, row.timestampDescription, session.stateSummary, keyHelp,
               keyboardSelected && !jumping ? (row.needsReview ? "⌘U Mark read" : "⌘U Mark unread") : nil]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"))
        .accessibilityLabel(session.title)
        .accessibilityValue([session.source.name, isMain ? "Main agent" : nil, row.stateTitle,
                             cueDescription, row.showsUnreadDot ? "Unread" : nil,
                             row.timestampDescription, session.stateSummary,
                             !jumping && directShortcut ? "Shortcut Control Option \(position)" : "Row \(position)"]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(keyboardSelected || previewSelected ? .isSelected : [])
    }

    private var briefingBackground: Color {
        if selected { return colors.selection }
        return isNext ? row.visualState.tint(colors).opacity(0.07) : .clear
    }

    private var briefingContent: some View {
        HStack(alignment: .top, spacing: OverlayMetrics.rowSpacing) {
            SessionStateIcon(state: row.visualState, colors: colors)
            VStack(alignment: .leading, spacing: OverlayMetrics.briefingLineGap) {
                title(compact: false)
                    .frame(height: OverlayMetrics.briefingTitleHeight)
                if let summary = session.stateSummary, !summary.isEmpty {
                    StateSummary(summary: summary, colors: colors, lineLimit: 2)
                }
                RowMetadata(row: row, colors: colors)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 4) {
                number
                if let timestamp = row.timestamp {
                    RowTimestamp(date: timestamp, now: now, colors: colors)
                        .frame(minWidth: OverlayMetrics.shortcutWidth)
                }
            }
            .frame(width: max(numberWidth, OverlayMetrics.briefingTailWidth), alignment: .trailing)
        }
    }

    private var compactContent: some View {
        HStack(spacing: 7) {
            number
                .frame(width: numberWidth)
            SessionStateIcon(state: row.visualState, colors: colors)
            title(compact: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if row.showsUnreadDot {
                Circle()
                    .fill(colors.secondary)
                    .frame(width: 4, height: 4)
            }
            Text(row.stateTitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(row.visualState.tint(colors))
                .fixedSize()
            if !jumping {
                ZStack(alignment: .trailing) {
                    Color.clear
                    if let timestamp = row.timestamp {
                        RowTimestamp(date: timestamp, now: now, colors: colors)
                    }
                }
                .frame(width: OverlayMetrics.timestampWidth)
            }
        }
    }

    private var number: some View {
        RowNumber(label: String(position), highlighted: selected, colors: colors, outlined: !compact)
            .accessibilityHidden(true)
    }

    private func title(compact: Bool) -> some View {
        HStack(spacing: 5) {
            Text(session.title)
                .font(.system(size: compact ? 13 : 14, weight: compact ? .medium : .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            if isMain {
                Text("Main")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(colors.secondary)
                    .padding(.horizontal, 4)
                    .frame(height: 15)
                    .background(colors.inset, in: RoundedRectangle(cornerRadius: 4))
                    .fixedSize()
                    .accessibilityHidden(true)
            }
            if let cue {
                let tint = isNext ? row.visualState.tint(colors) : colors.secondary
                Text(cue)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 4)
                    .frame(height: 15)
                    .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 4))
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
                SessionStateIcon(state: row.visualState, colors: colors)
                    .frame(height: 20)
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
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
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
