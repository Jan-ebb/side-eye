import Foundation
import Combine

enum SessionFilter: CaseIterable, Hashable {
    case all, needsInput, toReview

    var label: String {
        switch self {
        case .all: "All"
        case .needsInput: "Needs input"
        case .toReview: "To review"
        }
    }

    fileprivate func includes(_ row: SessionRow) -> Bool {
        switch self {
        case .all: true
        case .needsInput: row.session.status == .needsInput
        case .toReview: row.session.status == .ready && row.needsReview
        }
    }
}

@MainActor
final class SessionStore: ObservableObject {
    nonisolated static let automationRunsPreferenceKey = "showsAutomationRuns"
    private static let briefingPreferenceKey = "sidebarUsesBriefing"
    private static let staleAge: TimeInterval = 8 * 60 * 60
    @Published private(set) var rows: [SessionRow] = []
    @Published private(set) var hiddenCount = 0
    @Published private(set) var isLoading = true
    @Published var keyboardMode = false
    @Published var selectedID: String?
    @Published var notice: String?
    @Published private(set) var query = ""
    @Published private(set) var filter: SessionFilter = .all
    @Published private(set) var showsAllSummaries: Bool
    @Published private(set) var showsAutomationRuns: Bool
    @Published var numberEntry: String?
    @Published private(set) var grokMainOnly = false
    @Published private(set) var mainGrokIDs: Set<String> = []
    @Published private(set) var availableGrokSessions: [Session] = []

    var onAttention: (([Session]) -> Void)?
    var onRowsChanged: (() -> Void)?
    var attentionCount: Int { rows.lazy.filter(Self.needsAction).count }
    func count(for filter: SessionFilter) -> Int {
        filter == .all ? rows.count : rows.lazy.filter(filter.includes).count
    }

    var shownRows: [SessionRow] {
        var visible = matchingRows
        let nextAction = visible.indices.lazy.filter { Self.needsAction(visible[$0]) }.min { lhs, rhs in
            Self.actionFirst(visible[lhs], visible[rhs])
        }
        if let nextAction, nextAction > 0 {
            let row = visible.remove(at: nextAction)
            visible.insert(row, at: 0)
        }
        return visible
    }

    private var matchingRows: [SessionRow] {
        let scoped = filter == .all ? rows : rows.filter(filter.includes)
        let terms = query.split(whereSeparator: \.isWhitespace)
        if terms.isEmpty { return scoped }
        return scoped.filter { row in
            let text = [row.session.title, row.session.source.name, row.session.detail, row.statusLabel,
                        row.needsReview ? "Unread" : "", row.session.stateSummary ?? ""]
                .joined(separator: " ")
            return terms.allSatisfy { text.localizedStandardContains(String($0)) }
        }
    }

    var nextActionID: String? {
        guard let first = shownRows.first, Self.needsAction(first) else { return nil }
        return first.id
    }

    var latestReplyID: String? {
        shownRows.lazy.map(\.session).filter { $0.status == .ready }.min { first, second in
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

    func setQuery(_ value: String) {
        let nextQuery = String(value.prefix(80))
        let changed = nextQuery != query
        if changed { query = nextQuery }
        syncSelection(resetNumber: changed)
        if changed { onRowsChanged?() }
    }

    var workingCount: Int { rows.filter { $0.session.status == .working }.count }

    private struct Receipt: Codable, Equatable {
        var status: SessionStatus
        var activityID: String?
        var seenAt: Date
    }

    private struct History: Codable, Equatable {
        var dismissed: [String: Date] = [:]
        var seen: [String: Receipt] = [:]
        var links: [Session] = []
        var lastOpened: String?
        var completions: [String: Date]?
        var manuallyUnread: Set<String>?
    }

    private let defaults: UserDefaults?
    private var history = History()
    private var latest: [String: Session] = [:]
    private var lastDismissed: String?
    private var missingOnce = Set<String>()

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        showsAllSummaries = defaults?.bool(forKey: Self.briefingPreferenceKey) ?? false
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
               shouldReview(session, includingManual: false) {
                attention.append(session)
            }
        }

        history.completions = completions.isEmpty ? nil : completions
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
        shouldReview(session, includingManual: false)
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
        rows.filter(\.needsReview).map(\.session).sorted(by: Self.attentionFirst).first
    }

    func session(in position: Int) -> Session? {
        session(in: position, among: shownRows)
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
        let id = allowSelection ? selectedID : history.lastOpened
        return rows.first { $0.id == id }?.session
    }

    func hide(_ session: Session) {
        let index = shownRows.firstIndex { $0.id == session.id }
        history.dismissed[session.id] = Date()
        lastDismissed = session.id
        rebuild()
        let visible = shownRows
        if let index, !visible.isEmpty, (numberEntry ?? "").isEmpty {
            selectedID = visible[min(index, visible.count - 1)].id
        }
        persist()
    }

    func undoHide() -> Bool {
        guard let lastDismissed, history.dismissed.removeValue(forKey: lastDismissed) != nil else {
            return false
        }
        self.lastDismissed = nil
        rebuild()
        persist()
        return true
    }

    func restoreHidden() {
        history.dismissed.removeAll()
        rebuild()
        persist()
    }

    func addLink(title: String, source: Source, url: URL) {
        if let existing = history.links.first(where: { $0.route == .url(url.absoluteString) }) {
            history.dismissed.removeValue(forKey: existing.id)
            history.links.removeAll { $0.id == existing.id }
            latest.removeValue(forKey: existing.id)
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

        let staleBefore = now.addingTimeInterval(-Self.staleAge)
        let result = latest.values.filter { isVisible($0) }.sorted(by: Self.completionFirst).map { session in
            let needsReview = shouldReview(session)
            let lastActivity = max(session.updatedAt, session.completedAt ?? .distantPast)
            return SessionRow(session: session, needsReview: needsReview,
                              isManuallyUnread: history.manuallyUnread?.contains(session.id) == true,
                              isStale: session.status == .idle && !needsReview &&
                                lastActivity > .distantPast && lastActivity <= staleBefore)
        }
        if hiddenCount != history.dismissed.count { hiddenCount = history.dismissed.count }
        if rows != result {
            rows = result
            syncSelection()
            onRowsChanged?()
        }
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
                nextSelection = visible.contains { $0.id == selectedID } ? selectedID : visible.first?.id
            }
        }
        if selectedID != nextSelection { selectedID = nextSelection }
    }

    private func shouldReview(_ session: Session, includingManual: Bool = true) -> Bool {
        guard isVisible(session) else { return false }
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
