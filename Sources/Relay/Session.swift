import Foundation

enum Source: String, Codable, CaseIterable, Sendable {
    case codex, claude, cursor, grok, instinct

    var name: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Code"
        case .cursor: "Cursor"
        case .grok: "Grok Bot"
        case .instinct: "Instinct"
        }
    }

    var icon: String {
        switch self {
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .claude: "asterisk"
        case .cursor: "cursorarrow"
        case .grok: "bolt"
        case .instinct: "bubble.left"
        }
    }

    var enabledKey: String { "sourceEnabled." + rawValue }
    func isEnabled(in defaults: UserDefaults?) -> Bool {
        defaults?.object(forKey: enabledKey) as? Bool ?? (self != .instinct)
    }
}

enum SessionStatus: String, Codable, Sendable {
    case working, needsInput, ready, idle, unknown

    var name: String {
        switch self {
        case .working: "Working"
        case .needsInput: "Needs input"
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

struct SessionRow: Identifiable, Equatable {
    let session: Session
    let needsReview: Bool
    var isManuallyUnread = false
    var isStale = false
    var id: String { session.id }

    var statusLabel: String {
        switch session.status {
        case .ready: needsReview ? "To review" : "Read"
        case .idle: isStale ? "Inactive" : "Quiet"
        default: session.status.name
        }
    }
}
