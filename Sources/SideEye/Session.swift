import Foundation

enum Source: String, Codable, CaseIterable, Sendable {
    case codex, claude, cursor, grok

    var name: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Code"
        case .cursor: "Cursor"
        case .grok: "Grok Bot"
        }
    }

    var icon: String {
        switch self {
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .claude: "asterisk"
        case .cursor: "cursorarrow"
        case .grok: "bolt"
        }
    }

    /// True when the app has left data on this Mac for Side Eye to read. Without it there is nothing to find.
    var hasLocalData: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = home.appending(path: "Library/Application Support")
        let folders: [URL]
        switch self {
        case .codex: folders = [home.appending(path: ".codex")]
        case .claude: folders = [home.appending(path: ".claude"), support.appending(path: "Claude/claude-code-sessions")]
        case .cursor: folders = [support.appending(path: "Cursor")]
        case .grok: folders = [support.appending(path: "Grok Bot")]
        }
        return folders.contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    var enabledKey: String { "sourceEnabled." + rawValue }
    func isEnabled(in defaults: UserDefaults?) -> Bool {
        defaults?.object(forKey: enabledKey) as? Bool ?? true
    }
}

enum SessionStatus: String, Codable, Sendable {
    case working, needsInput, ready, idle, unknown

    var name: String {
        switch self {
        case .working: "Working"
        case .needsInput: "Needs you"
        case .ready: "Ready"
        case .idle: "Idle"
        case .unknown: "Status unavailable"
        }
    }

    var requestsAttention: Bool { self == .needsInput || self == .ready }
}

enum Route: Codable, Hashable, Sendable {
    case url(String)
    case claude(sessionID: String, directory: String, tty: String?)
    case claudeBackground(id: String, directory: String)
}

struct Session: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let source: Source
    let title: String
    var detail: String = ""
    let status: SessionStatus
    let updatedAt: Date
    let route: Route
    var activityID: String? = nil
    var reviewedBySource: Bool? = nil
    var completedAt: Date? = nil
    var stateSummary: String? = nil
    var isAutomationRun: Bool? = nil

    func hasSameActivity(as other: Session) -> Bool {
        guard id == other.id, status == other.status else { return false }
        if activityID != nil || other.activityID != nil { return activityID == other.activityID }
        return updatedAt == other.updatedAt
    }
}

/// A Grok Bot agent Settings can offer as a main agent, whether or not it has a recent chat.
struct GrokAgent: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    var createdAt: Date? = nil

    /// Created in the last week: worth pointing out in Settings while it is still unfamiliar.
    func isNew(now: Date = Date()) -> Bool {
        createdAt.map { now.timeIntervalSince($0) < 7 * 24 * 3_600 } ?? false
    }
}

struct SessionRow: Identifiable, Equatable {
    let session: Session
    let needsReview: Bool
    var isManuallyUnread = false
    var isStale = false
    var id: String { session.id }

    /// The status in a word or two, for rows that sit outside the Inbox's groups. Nil when the app
    /// reports no status, so the row does not carry a label that says nothing.
    var shortState: String? {
        switch session.status {
        case .needsInput: "Needs you"
        case .ready: needsReview ? "Review" : "Read"
        case .working: "Working"
        case .idle: "Idle"
        case .unknown: nil
        }
    }

    var statusLabel: String {
        switch session.status {
        case .ready: needsReview ? "Review" : "Read"
        case .idle: isStale ? "Inactive" : "Idle"
        default: session.status.name
        }
    }
}
