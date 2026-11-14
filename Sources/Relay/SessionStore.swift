import Foundation
import Combine

enum SessionFilter: CaseIterable, Hashable {
    case all, favorites, needsInput, toReview, later, archive

    // Needs input and To review are groups inside All rather than tabs. The filters stay for
    // the counts the pill and nudges use.
    static let tabs: [SessionFilter] = [.all, .favorites, .later]

    var label: String {
        switch self {
        case .all: "All"
        case .favorites: "Favorites"
        case .needsInput: "Needs input"
        case .toReview: "To review"
        case .later: "Later"
        case .archive: "Archive"
        }
    }

    fileprivate func includes(_ row: SessionRow) -> Bool {
        switch self {
        case .all: true
        case .needsInput: row.session.status == .needsInput
        case .toReview: row.session.status == .ready && row.needsReview
        case .favorites, .later, .archive: false
        }
    }
}

/// Where a chat sits in All and Later. Groups follow what the agent is doing, never whether you
/// have read it, so opening a chat changes how its row looks but not where it is.
enum SessionGroup: Int, CaseIterable, Hashable {
    case needsInput, finished, working, quiet

    init(_ row: SessionRow) {
        switch row.session.status {
        case .needsInput: self = .needsInput
        // A reply you have read drifts to Quiet only after eight quiet hours.
        case .ready: self = row.isStale ? .quiet : .finished
        case .working: self = .working
        case .idle, .unknown: self = .quiet
        }
    }

    var label: String {
        switch self {
        case .needsInput: "Needs input"
        case .finished: "Finished"
        case .working: "Working"
        case .quiet: "Idle"
        }
    }

    var headerID: String { "group-\(rawValue)" }
}

struct RowSection: Equatable {
    let group: SessionGroup?
    let rows: [SessionRow]
    let total: Int
    var isCollapsed: Bool { rows.isEmpty && total > 0 }
}

enum SidebarItem: Identifiable, Equatable {
    case allClear
    case header(SessionGroup, count: Int, collapsed: Bool)
    case row(SessionRow, position: Int)

    var id: String {
        switch self {
        case .allClear: "all-clear"
        case .header(let group, _, _): group.headerID
        case .row(let row, _): row.id
        }
    }
}

@MainActor
final class SessionStore: ObservableObject {
    nonisolated static let automationRunsPreferenceKey = "showsAutomationRuns"
    private static let briefingPreferenceKey = "sidebarUsesBriefing"
    private static let quietCollapsedPreferenceKey = "sidebarQuietCollapsed"
    private static let pinnedPreferenceKey = "pinnedSessionIDs"
    static let maxPins = 9
    private static let staleAge: TimeInterval = 8 * 60 * 60
    @Published private(set) var rows: [SessionRow] = []
    @Published private var laterRows: [SessionRow] = []
    @Published private var archiveRows: [SessionRow] = []
    @Published private(set) var hiddenCount = 0
    @Published private(set) var isLoading = true
    @Published var keyboardMode = false
    @Published var selectedID: String?
    @Published var notice: String?
    @Published var noticeOffersUndo = false
    @Published private var searchQuery: String?
    @Published private(set) var filter: SessionFilter = .all
    @Published private(set) var showsAllSummaries: Bool
    @Published private(set) var quietCollapsed: Bool
    /// Favorites, in the order they were added. They stay in their groups in All and have their own tab.
    @Published private(set) var pinnedIDs: [String]
    @Published private(set) var showsAutomationRuns: Bool
    @Published var numberEntry: String?
    /// The ⌘K palette while it is open.
    @Published var palette: PaletteState?
    @Published private(set) var grokMainOnly = false
    @Published private(set) var mainGrokIDs: Set<String> = []
    @Published private(set) var availableGrokSessions: [Session] = []

    var onAttention: (([Session]) -> Void)?
    var onRowsChanged: (() -> Void)?
    var query: String { searchQuery ?? "" }
    var isSearching: Bool { searchQuery != nil }
    var missingArchiveCount: Int { max(0, hiddenCount - archiveRows.count) }
    private var activeRows: [SessionRow] { laterRows.isEmpty ? rows : rows.filter { !isDeferred($0.id) } }
    var attentionCount: Int { activeRows.lazy.filter(Self.needsAction).count }
    func count(for filter: SessionFilter) -> Int {
        if filter == .later { return laterRows.count }
        if filter == .archive { return archiveRows.count }
        if filter == .favorites { return favoriteRows.count }
        return activeRows.lazy.filter(filter.includes).count
    }

    /// All and Later show their rows grouped by what they ask of you. Quiet folds away in All
    /// until it's opened or a search needs it.
    var groupsRows: Bool { filter == .all || filter == .later }

    var sections: [RowSection] {
        var visible = matchingRows
        guard groupsRows else {
            // Favorites keep the order you added them in, so their numbers never change.
            if filter != .archive, filter != .favorites, let nextAction = visible.indices.lazy
                .filter({ Self.needsAction(visible[$0]) })
                .min(by: { Self.actionFirst(visible[$0], visible[$1]) }), nextAction > 0 {
                let row = visible.remove(at: nextAction)
                visible.insert(row, at: 0)
            }
            return visible.isEmpty ? [] : [RowSection(group: nil, rows: visible, total: visible.count)]
        }
        var sections: [RowSection] = []
        // Dictionary(grouping:) keeps each group's rows in their incoming order, which Later relies on.
        let grouped = Dictionary(grouping: visible, by: SessionGroup.init)
        for group in SessionGroup.allCases {
            guard let members = grouped[group], !members.isEmpty else { continue }
            let ordered = filter == .later ? members : members.sorted(by: order(within: group))
            let folded = group == .quiet && foldsQuiet && quietCollapsed
            sections.append(RowSection(group: group, rows: folded ? [] : ordered, total: ordered.count))
        }
        return sections
    }

    var shownRows: [SessionRow] { sections.flatMap(\.rows) }

    /// Quiet can fold only in All, and a search always looks inside it.
    var foldsQuiet: Bool { filter == .all && !isSearching }

    /// What ↑ and ↓ step through: the rows, plus the Quiet header so ↵ can fold or open it.
    var navigableIDs: [String] {
        sections.flatMap { section -> [String] in
            if section.group == .quiet && foldsQuiet { return [SessionGroup.quiet.headerID] + section.rows.map(\.id) }
            return section.rows.map(\.id)
        }
    }

    var isQuietHeaderSelected: Bool { selectedID == SessionGroup.quiet.headerID }

    /// The list as drawn: an all-clear line when nothing needs you, group headers and numbered rows.
    var sidebarItems: [SidebarItem] {
        let sections = self.sections
        var items: [SidebarItem] = []
        if filter == .all, !isSearching, numberEntry == nil, !sections.isEmpty,
           !matchingRows.contains(where: Self.needsAction) {
            items.append(.allClear)
        }
        var position = 0
        for section in sections {
            if let group = section.group {
                items.append(.header(group, count: section.total, collapsed: section.isCollapsed))
            }
            for row in section.rows {
                position += 1
                items.append(.row(row, position: position))
            }
        }
        return items
    }

    func setQuietCollapsed(_ value: Bool) {
        guard value != quietCollapsed else { return }
        // Folding with a quiet chat selected keeps your place on the header.
        if value, let selectedID, rows.contains(where: { $0.id == selectedID && SessionGroup($0) == .quiet }) {
            self.selectedID = SessionGroup.quiet.headerID
        }
        quietCollapsed = value
        defaults?.set(value, forKey: Self.quietCollapsedPreferenceKey)
        syncSelection()
        onRowsChanged?()
    }

    /// Moves the selection to the next or previous group: its first row, or its header when folded.
    /// Returns false at either end of the list.
    @discardableResult
    func selectGroup(forward: Bool) -> Bool {
        guard groupsRows else { return false }
        let anchors: [(members: Set<String>, target: String)] = sections.compactMap { section in
            var members = Set(section.rows.map(\.id))
            if let group = section.group { members.insert(group.headerID) }
            guard let target = section.isCollapsed ? section.group?.headerID : section.rows.first?.id else { return nil }
            return (members, target)
        }
        guard !anchors.isEmpty else { return false }
        let target: Int
        if let current = anchors.firstIndex(where: { $0.members.contains(selectedID ?? "") }) {
            target = current + (forward ? 1 : -1)
        } else {
            target = forward ? 0 : anchors.count - 1
        }
        guard anchors.indices.contains(target) else { return false }
        selectedID = anchors[target].target
        return true
    }

    func isPinned(_ id: String) -> Bool { pinnedIDs.contains(id) }

    /// Favorites that are not in Later, in the order they were added.
    private var favoriteRows: [SessionRow] {
        pinnedIDs.compactMap { id in activeRows.first { $0.id == id } }
    }

    /// Stars a chat or removes its star. The chat stays where it is in All and appears in the
    /// Favorites tab. Returns nil when Favorites is full.
    @discardableResult
    func togglePin(_ session: Session) -> Bool? {
        if let index = pinnedIDs.firstIndex(of: session.id) {
            pinnedIDs.remove(at: index)
        } else {
            // Forget favorites whose chats are gone, keeping ones resting in Later.
            let live = pinnedIDs.filter { id in rows.contains { $0.id == id } }
            guard live.count < Self.maxPins else { return nil }
            pinnedIDs = live + [session.id]
        }
        defaults?.set(pinnedIDs, forKey: Self.pinnedPreferenceKey)
        syncSelection()
        onRowsChanged?()
        return pinnedIDs.contains(session.id)
    }

    var canUndo: Bool { lastChange != nil }

    private var matchingRows: [SessionRow] {
        let scoped: [SessionRow]
        switch filter {
        case .all: scoped = activeRows
        case .favorites: scoped = favoriteRows
        case .needsInput, .toReview: scoped = activeRows.filter(filter.includes)
        case .later: scoped = laterRows
        case .archive: scoped = archiveRows
        }
        let terms = query.split(whereSeparator: \.isWhitespace)
        if terms.isEmpty { return scoped }
        return scoped.filter { row in
            let text = [row.session.title, row.session.source.name, row.session.detail, row.statusLabel,
                        row.needsReview ? "Unread" : "", row.isStale ? "Stale" : "", row.session.stateSummary ?? ""]
                .joined(separator: " ")
            return terms.allSatisfy { text.localizedStandardContains(String($0)) }
        }
    }

    /// The chat to act on next: a new input request, then an unread reply, then a pending request.
    /// It is selected when the sidebar opens, wherever it sits in the list.
    var nextActionID: String? {
        guard filter != .later, filter != .archive else { return nil }
        return shownRows.enumerated().filter { Self.needsAction($0.element) }.min { lhs, rhs in
            let first = Self.actionPriority(lhs.element)
            let second = Self.actionPriority(rhs.element)
            return first != second ? first < second : lhs.offset < rhs.offset
        }?.element.id
    }

    var latestReplyID: String? {
        matchingRows.lazy.map(\.session).filter { $0.status == .ready }.min { first, second in
            let firstReply = first.completedAt ?? first.updatedAt
            let secondReply = second.completedAt ?? second.updatedAt
            if firstReply != secondReply { return firstReply > secondReply }
            return Self.completionFirst(first, second)
        }?.id
    }

    func setFilter(_ value: SessionFilter) {
        guard value != filter else { return }
        filter = value
        syncSelection(resetNumber: true)
        onRowsChanged?()
    }

    func setShowsAllSummaries(_ value: Bool) {
        guard value != showsAllSummaries else { return }
        showsAllSummaries = value
        defaults?.set(value, forKey: Self.briefingPreferenceKey)
        onRowsChanged?()
    }

    func setShowsAutomationRuns(_ value: Bool) {
        guard value != showsAutomationRuns else { return }
        showsAutomationRuns = value
        defaults?.set(value, forKey: Self.automationRunsPreferenceKey)
        rebuild()
    }

    func setQuery(_ value: String?) {
        let nextQuery = value.map { String($0.prefix(80)) }
        let changed = nextQuery != searchQuery
        if changed { searchQuery = nextQuery }
        syncSelection(resetNumber: changed)
        if changed { onRowsChanged?() }
    }

    var workingCount: Int { activeRows.lazy.filter { $0.session.status == .working }.count }

    private struct Receipt: Codable, Equatable {
        var status: SessionStatus
        var activityID: String?
        var seenAt: Date
    }

    private struct SavedSession: Codable, Equatable {
        let snapshot: Session
        let deferredAt: Date?
        /// When a chat in Later comes back by itself. Nil keeps it until you move it back.
        var until: Date? = nil
    }

    private struct History: Codable, Equatable {
        var dismissed: [String: Date] = [:]
        var seen: [String: Receipt] = [:]
        var links: [Session] = []
        var lastOpened: String?
        var completions: [String: Date]?
        var manuallyUnread: Set<String>?
        var savedSessions: [String: SavedSession]?
    }

    private enum LastChange {
        case archive(String)
        case later(String, previous: SavedSession?)
    }

    private let defaults: UserDefaults?
    private var history = History()
    private var latest: [String: Session] = [:]
    private var lastChange: LastChange?
    private var missingOnce = Set<String>()
    /// When each working chat started its turn, so Working keeps a steady order while agents report activity.
    private var workingSince: [String: Date] = [:]

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        showsAllSummaries = defaults?.bool(forKey: Self.briefingPreferenceKey) ?? false
        quietCollapsed = defaults?.object(forKey: Self.quietCollapsedPreferenceKey) as? Bool ?? true
        pinnedIDs = defaults?.stringArray(forKey: Self.pinnedPreferenceKey) ?? []
        showsAutomationRuns = defaults?.bool(forKey: Self.automationRunsPreferenceKey) ?? false
        grokMainOnly = defaults?.bool(forKey: "grokMainAgentsOnly") ?? false
        mainGrokIDs = Set(defaults?.stringArray(forKey: "grokMainAgentIDs") ?? [])
        if let data = defaults?.data(forKey: "sessionHistory"),
           let decoded = try? JSONDecoder().decode(History.self, from: data) {
            history = decoded
        }
        let expiry = Date().addingTimeInterval(-90 * 24 * 60 * 60)
        history.seen = history.seen.filter { $0.value.seenAt >= expiry }
        history.completions = history.completions?.filter { $0.value >= expiry }
        hiddenCount = history.dismissed.count
        if history.savedSessions != nil { rebuild() }
    }

    func ingest(_ sessions: [Session], now: Date = Date()) {
        var combined: [String: Session] = [:]
        for session in history.links + sessions {
            if let existing = combined[session.id], existing.updatedAt > session.updatedAt { continue }
            combined[session.id] = session
        }

        // Keep sessions through a single scan if a data store is temporarily unavailable.
        let missing = Set(latest.keys).subtracting(combined.keys)
        for id in missing.subtracting(missingOnce) {
            combined[id] = latest[id]
        }
        missingOnce = missing

        let oldHistory = history
        var completions = history.completions ?? [:]
        var attention: [Session] = []
        for (id, var session) in combined {
            if let completedAt = session.completedAt, completedAt > (completions[id] ?? .distantPast) {
                completions[id] = completedAt
            }
            session.completedAt = completions[id]
            combined[id] = session
            let before = latest[id]
            let signalChanged = before.map { !$0.hasSameActivity(as: session) } ?? false
            if !session.status.requestsAttention {
                if session.status == .working { history.seen.removeValue(forKey: session.id) }
                continue
            }
            let isNew = before == nil && session.updatedAt >= now.addingTimeInterval(-12)
            if !isLoading, (signalChanged || isNew),
               isAttentionPending(for: session) {
                attention.append(session)
            }
        }

        history.completions = completions.isEmpty ? nil : completions
        for id in history.dismissed.keys where history.savedSessions?[id] == nil {
            if let session = combined[id] {
                saveSession(SavedSession(snapshot: Self.snapshot(of: session), deferredAt: nil), id: id)
            }
        }
        pruneRecoveredSnapshots(in: combined)
        latest = combined
        if isLoading { isLoading = false }
        rebuild(now: now)
        if oldHistory != history { persist() }
        if !attention.isEmpty {
            onAttention?(attention.sorted(by: Self.attentionFirst))
        }
    }

    func applySummaries(from sessions: [Session]) {
        var changed = false
        for update in sessions {
            guard var current = latest[update.id], current.hasSameActivity(as: update),
                  current.stateSummary != update.stateSummary else { continue }
            current.stateSummary = update.stateSummary
            latest[update.id] = current
            changed = true
        }
        if changed { rebuild() }
    }

    func isAttentionPending(for session: Session) -> Bool {
        isVisible(session) && !isDeferred(session.id) && shouldReview(session, includingManual: false)
    }

    func acknowledge(_ session: Session) {
        let live = latest[session.id] ?? session
        recordRead(live)
        history.lastOpened = live.id
        rebuild()
        persist()
    }

    func markRead(_ session: Session) {
        recordRead(latest[session.id] ?? session)
        rebuild()
        persist()
    }

    func markUnread(_ session: Session) {
        var unread = history.manuallyUnread ?? []
        guard unread.insert(session.id).inserted else { return }
        history.manuallyUnread = unread
        rebuild()
        persist()
    }

    private func recordRead(_ session: Session) {
        if var unread = history.manuallyUnread {
            unread.remove(session.id)
            history.manuallyUnread = unread.isEmpty ? nil : unread
        }
        if session.status.requestsAttention {
            history.seen[session.id] = Receipt(status: session.status, activityID: session.activityID,
                                               seenAt: max(Date(), session.updatedAt))
        }
    }

    func nextAttention() -> Session? {
        activeRows.filter(\.needsReview).map(\.session).sorted(by: Self.attentionFirst).first
    }

    func session(in position: Int) -> Session? {
        session(in: position, among: shownRows)
    }

    func session(id: String) -> Session? {
        rows.first { $0.id == id }?.session ?? archiveRows.first { $0.id == id }?.session
    }

    private func session(in position: Int, among visible: [SessionRow]) -> Session? {
        guard position > 0, position <= visible.count else { return nil }
        return visible[position - 1].session
    }

    var enteredSession: Session? {
        guard let numberEntry, let position = Int(numberEntry) else { return nil }
        return session(in: position)
    }

    func appendJumpDigit(_ digit: String) {
        guard let numberEntry, digit.utf8.count == 1, let byte = digit.utf8.first,
              (48...57).contains(byte) else { return }
        let visible = shownRows
        let entry = numberEntry + digit
        guard !visible.isEmpty, entry.count <= String(visible.count).count,
              let position = Int(entry), position > 0 else { return }
        self.numberEntry = entry
        selectedID = session(in: position, among: visible)?.id
    }

    func setGrokMainOnly(_ enabled: Bool) {
        guard enabled != grokMainOnly else { return }
        grokMainOnly = enabled
        defaults?.set(enabled, forKey: "grokMainAgentsOnly")
        rebuild()
    }

    func toggleGrokMain(id: String) {
        setGrokMain(id: id, isMain: !mainGrokIDs.contains(id))
    }

    func setGrokMain(id: String, isMain: Bool) {
        var selection = mainGrokIDs
        if isMain {
            guard latest[id]?.source == .grok, selection.insert(id).inserted else { return }
        } else {
            guard selection.remove(id) != nil else { return }
        }
        mainGrokIDs = selection
        defaults?.set(mainGrokIDs.sorted(), forKey: "grokMainAgentIDs")
        rebuild()
    }

    func removeTarget(allowSelection: Bool) -> Session? {
        if allowSelection {
            guard filter != .archive else { return nil }
            return shownRows.first { $0.id == selectedID }?.session
        }
        return rows.first { $0.id == history.lastOpened }?.session
    }

    func hide(_ session: Session) {
        guard let current = rows.first(where: { $0.id == session.id })?.session else { return }
        let index = shownRows.firstIndex { $0.id == current.id }
        let deferredAt = history.savedSessions?[current.id]?.deferredAt
        saveSession(SavedSession(snapshot: Self.snapshot(of: current), deferredAt: deferredAt), id: current.id)
        history.dismissed[current.id] = Date()
        lastChange = .archive(current.id)
        rebuild()
        selectRow(afterRemoving: index)
        persist()
    }

    @discardableResult
    func restoreArchived(_ session: Session) -> Bool {
        guard history.dismissed.removeValue(forKey: session.id) != nil else { return false }
        let index = shownRows.firstIndex { $0.id == session.id }
        if case .archive(let id) = lastChange, id == session.id { lastChange = nil }
        pruneRecoveredSnapshots(in: latest)
        rebuild()
        selectRow(afterRemoving: index)
        persist()
        return true
    }

    @discardableResult
    func toggleLater(_ session: Session) -> Bool? {
        guard let current = rows.first(where: { $0.id == session.id })?.session else { return nil }
        let index = shownRows.firstIndex { $0.id == current.id }
        let previous = history.savedSessions?[current.id]
        let deferSession = previous?.deferredAt == nil
        if deferSession {
            saveSession(SavedSession(snapshot: Self.snapshot(of: current), deferredAt: Date()), id: current.id)
        } else if latest[current.id] == nil, let previous {
            saveSession(SavedSession(snapshot: previous.snapshot, deferredAt: nil), id: current.id)
        } else {
            saveSession(nil, id: current.id)
        }
        lastChange = .later(current.id, previous: previous)
        rebuild()
        selectRow(afterRemoving: index)
        persist()
        return deferSession
    }

    /// Moves a chat to Later until a time, when it comes back to All marked unread.
    /// A chat already in Later just gets the new time.
    @discardableResult
    func deferSession(_ session: Session, until: Date?) -> Bool {
        guard let current = rows.first(where: { $0.id == session.id })?.session else { return false }
        let index = shownRows.firstIndex { $0.id == current.id }
        let previous = history.savedSessions?[current.id]
        saveSession(SavedSession(snapshot: Self.snapshot(of: current), deferredAt: previous?.deferredAt ?? Date(),
                                 until: until), id: current.id)
        lastChange = .later(current.id, previous: previous)
        rebuild()
        selectRow(afterRemoving: index)
        persist()
        return true
    }

    /// When a chat in Later is due back, or nil if it waits for you.
    func returnDate(for id: String) -> Date? {
        history.savedSessions?[id]?.until
    }

    /// Brings back chats whose Later time has passed, marked unread so they get noticed.
    private func returnDueChats(now: Date) {
        guard let saved = history.savedSessions else { return }
        let due = saved.filter { _, entry in entry.deferredAt != nil && (entry.until.map { $0 <= now } ?? false) }
        guard !due.isEmpty else { return }
        var unread = history.manuallyUnread ?? []
        for (id, entry) in due {
            saveSession(latest[id] == nil ? SavedSession(snapshot: entry.snapshot, deferredAt: nil) : nil, id: id)
            unread.insert(id)
        }
        history.manuallyUnread = unread
        if case .later(let id, _) = lastChange, due[id] != nil { lastChange = nil }
        persist()
    }

    private func selectRow(afterRemoving index: Int?) {
        let visible = shownRows
        if let index, !visible.isEmpty, (numberEntry ?? "").isEmpty {
            selectedID = visible[min(index, visible.count - 1)].id
        }
    }

    private func saveSession(_ saved: SavedSession?, id: String) {
        var sessions = history.savedSessions ?? [:]
        sessions[id] = saved
        history.savedSessions = sessions.isEmpty ? nil : sessions
    }

    private static func snapshot(of session: Session) -> Session {
        // A saved route can outlive its source scan, but its reported state cannot.
        Session(id: session.id, source: session.source, title: session.title, detail: session.detail,
                status: .unknown, updatedAt: session.updatedAt, route: session.route,
                completedAt: session.completedAt, isAutomationRun: session.isAutomationRun)
    }

    private func pruneRecoveredSnapshots(in current: [String: Session]) {
        guard let saved = history.savedSessions else { return }
        let remaining = saved.filter { id, entry in
            entry.deferredAt != nil || history.dismissed[id] != nil || current[id] == nil
        }
        history.savedSessions = remaining.isEmpty ? nil : remaining
    }

    private func isDeferred(_ id: String) -> Bool {
        history.savedSessions?[id]?.deferredAt != nil
    }

    func undoHide() -> Bool {
        guard let lastChange else { return false }
        self.lastChange = nil
        switch lastChange {
        case .archive(let id):
            guard history.dismissed.removeValue(forKey: id) != nil else { return false }
            pruneRecoveredSnapshots(in: latest)
        case .later(let id, let previous):
            if previous == nil, latest[id] == nil, let saved = history.savedSessions?[id] {
                saveSession(SavedSession(snapshot: saved.snapshot, deferredAt: nil), id: id)
            } else {
                saveSession(previous, id: id)
            }
        }
        rebuild()
        persist()
        return true
    }

    func restoreHidden() {
        history.dismissed.removeAll()
        if case .archive = lastChange { lastChange = nil }
        pruneRecoveredSnapshots(in: latest)
        rebuild()
        persist()
    }

    func addLink(title: String, source: Source, url: URL) {
        if let existing = history.links.first(where: { $0.route == .url(url.absoluteString) }) {
            history.dismissed.removeValue(forKey: existing.id)
            history.links.removeAll { $0.id == existing.id }
            latest.removeValue(forKey: existing.id)
            saveSession(nil, id: existing.id)
        }
        let session = Session(id: "link:" + UUID().uuidString, source: source, title: title,
                              detail: "Pinned link", status: .unknown, updatedAt: Date(),
                              route: .url(url.absoluteString))
        history.links.append(session)
        latest[session.id] = session
        rebuild()
        persist()
    }

    func refreshPreferences() { rebuild() }

    private func rebuild(now: Date = Date()) {
        let grokAgents = latest.values.filter { $0.source == .grok && history.dismissed[$0.id] == nil }
            .sorted {
                let titleOrder = $0.title.localizedStandardCompare($1.title)
                return titleOrder == .orderedSame ? $0.id < $1.id : titleOrder == .orderedAscending
            }
        if availableGrokSessions != grokAgents { availableGrokSessions = grokAgents }

        returnDueChats(now: now)
        let staleBefore = now.addingTimeInterval(-Self.staleAge)
        let snapshots = history.savedSessions?.values.compactMap { saved in
            latest[saved.snapshot.id] == nil ? saved.snapshot : nil
        } ?? []
        let sessions = Array(latest.values) + snapshots
        let result = sessions.filter { isVisible($0) }.sorted(by: Self.completionFirst)
            .map { makeRow($0, staleBefore: staleBefore) }
        let deferred = result.compactMap { row -> (SessionRow, Date)? in
            guard let date = history.savedSessions?[row.id]?.deferredAt else { return nil }
            return (row, date)
        }.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.id < rhs.0.id
        }.map(\.0)
        let archived = history.dismissed.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key < rhs.key
        }.compactMap { id, _ in
            (latest[id] ?? history.savedSessions?[id]?.snapshot).map { makeRow($0, staleBefore: staleBefore) }
        }
        if hiddenCount != history.dismissed.count { hiddenCount = history.dismissed.count }
        let working = result.filter { $0.session.status == .working }
        workingSince = Dictionary(uniqueKeysWithValues: working.map { row in
            (row.id, workingSince[row.id] ?? row.session.updatedAt)
        })
        if rows != result || laterRows != deferred || archiveRows != archived {
            if rows != result { rows = result }
            if laterRows != deferred { laterRows = deferred }
            if archiveRows != archived { archiveRows = archived }
            syncSelection()
            onRowsChanged?()
        }
    }

    private func makeRow(_ session: Session, staleBefore: Date) -> SessionRow {
        let needsReview = shouldReview(session)
        let lastActivity = max(session.updatedAt, session.completedAt ?? .distantPast)
        return SessionRow(session: session, needsReview: needsReview,
                          isManuallyUnread: history.manuallyUnread?.contains(session.id) == true,
                          isStale: (session.status == .idle || session.status == .ready) && !needsReview &&
                            lastActivity > .distantPast && lastActivity <= staleBefore)
    }

    private func syncSelection(resetNumber: Bool = false) {
        let visible = shownRows
        let nextSelection: String?
        if visible.isEmpty {
            if numberEntry != nil { numberEntry = nil }
            nextSelection = nil
        } else {
            if let entry = numberEntry, !entry.isEmpty,
               resetNumber || entry.count > String(visible.count).count {
                numberEntry = ""
            }
            if let entry = numberEntry, !entry.isEmpty {
                nextSelection = Int(entry).flatMap { session(in: $0, among: visible)?.id }
            } else {
                nextSelection = navigableIDs.contains { $0 == selectedID } ? selectedID : visible.first?.id
            }
        }
        if selectedID != nextSelection { selectedID = nextSelection }
    }

    private func shouldReview(_ session: Session, includingManual: Bool = true) -> Bool {
        if includingManual && history.manuallyUnread?.contains(session.id) == true { return true }
        guard session.status.requestsAttention else { return false }
        if session.status == .ready && session.reviewedBySource == true { return false }
        guard let receipt = history.seen[session.id], receipt.status == session.status else { return true }
        if let activityID = session.activityID { return receipt.activityID != activityID }
        return session.updatedAt > receipt.seenAt
    }

    private func isVisible(_ session: Session) -> Bool {
        guard history.dismissed[session.id] == nil, session.source.isEnabled(in: defaults),
              showsAutomationRuns || session.isAutomationRun != true else { return false }
        return session.source != .grok || !grokMainOnly || mainGrokIDs.contains(session.id)
    }

    private static func needsAction(_ row: SessionRow) -> Bool {
        row.session.status == .needsInput || row.needsReview
    }

    private static func actionPriority(_ row: SessionRow) -> Int {
        switch (row.session.status, row.needsReview) {
        case (.needsInput, true): 0
        case (.ready, true): 1
        case (.needsInput, false): 2
        default: 3
        }
    }

    private static func actionFirst(_ a: SessionRow, _ b: SessionRow) -> Bool {
        let first = actionPriority(a)
        let second = actionPriority(b)
        if first != second { return first < second }
        return attentionFirst(a.session, b.session)
    }

    /// Newest first by the time the row shows. Needs input keeps unseen requests on top.
    /// Newest first, by a moment that reading never changes: when a request arrived, a reply
    /// finished, a turn started or a chat went quiet.
    private func order(within group: SessionGroup) -> (SessionRow, SessionRow) -> Bool {
        let since = workingSince
        return { a, b in
            let first = group == .working ? since[a.id] ?? a.session.updatedAt : Self.shownDate(a)
            let second = group == .working ? since[b.id] ?? b.session.updatedAt : Self.shownDate(b)
            return first != second ? first > second : a.id < b.id
        }
    }

    /// The same moment the row's timestamp shows; rows without one sort last.
    private static func shownDate(_ row: SessionRow) -> Date {
        let session = row.session
        switch session.status {
        case .ready: return session.completedAt ?? session.updatedAt
        case .idle: return max(session.updatedAt, session.completedAt ?? .distantPast)
        case .unknown: return .distantPast
        case .working, .needsInput: return session.updatedAt
        }
    }

    private static func completionFirst(_ a: Session, _ b: Session) -> Bool {
        let first = a.completedAt ?? .distantPast
        let second = b.completedAt ?? .distantPast
        if first != second { return first > second }
        if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
        return a.id < b.id
    }

    private static func attentionFirst(_ a: Session, _ b: Session) -> Bool {
        func rank(_ status: SessionStatus) -> Int {
            switch status {
            case .needsInput: 0
            case .ready: 1
            case .working: 2
            case .idle: 3
            case .unknown: 4
            }
        }
        if rank(a.status) != rank(b.status) { return rank(a.status) < rank(b.status) }
        if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
        return a.id < b.id
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(history) {
            defaults?.set(data, forKey: "sessionHistory")
        }
    }
}
