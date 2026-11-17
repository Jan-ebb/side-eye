import CryptoKit
import Foundation
import SQLite3

final class DesktopProvider: @unchecked Sendable {
    private static let recentInterval: TimeInterval = 48 * 60 * 60
    private let home: URL
    private let defaults: UserDefaults
    private var grokRosterURL: URL?
    private var grokRosterStamp: FileStamp?
    private var grokRows: [GrokRow] = []
    /// Every agent in Grok Bot's roster, however long ago it was active. Chats older than the scan
    /// window are not sessions, but Settings still needs to offer their agents as main agents.
    private(set) var grokAgents: [GrokAgent] = []
    private var grokTails: [String: (stamp: FileStamp, tail: GrokTail)] = [:]

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, defaults: UserDefaults = .standard) {
        self.home = home
        self.defaults = defaults
    }

    func scan() -> [Session] {
        let cutoff = Date().addingTimeInterval(-Self.recentInterval)
        let cursor = Source.cursor.isEnabled(in: defaults) ? cursorSessions(since: cutoff) : []
        let grok = Source.grok.isEnabled(in: defaults) ? grokSessions(since: cutoff) : []
        if !Source.grok.isEnabled(in: defaults) { grokAgents = [] }
        let instinct = Source.instinct.isEnabled(in: defaults) ? instinctSession() : []
        return cursor + grok + instinct
    }

    private func cursorSessions(since cutoff: Date) -> [Session] {
        let url = home.appending(path: "Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        guard let database = ReadOnlyDatabase(url) else { return [] }
        return cursorLocalSessions(in: database, since: cutoff) + cursorCloudSessions(in: database, since: cutoff)
    }

    private func cursorLocalSessions(in database: ReadOnlyDatabase, since cutoff: Date) -> [Session] {
        // Limit the recent headers first. Pull only the persisted generation status from the larger row.
        let query = """
        WITH recent AS (
            SELECT composerId, recency, value FROM composerHeaders
            WHERE COALESCE(isArchived, 0) = 0 AND COALESCE(isSubagent, 0) = 0 AND recency >= ?1
            ORDER BY recency DESC LIMIT 60
        )
        SELECT recent.composerId, recent.recency, recent.value,
            CASE WHEN json_valid(body.value) THEN json_extract(body.value, '$.status') END,
            CASE WHEN json_valid(body.value) THEN json_extract(body.value, '$.lastUpdatedAt') END
        FROM recent LEFT JOIN cursorDiskKV AS body ON body.key = 'composerData:' || recent.composerId
        """
        let cutoffMilliseconds = Int64(cutoff.timeIntervalSince1970 * 1000)
        return database.read(query, bind: { sqlite3_bind_int64($0, 1, cutoffMilliseconds) }) { row -> Session? in
            guard let id = row.string(0), Self.validAgentID(id),
                  let value = row.data(2),
                  let header = try? JSONDecoder().decode(CursorHeader.self, from: value),
                  header.isDraft != true else { return nil }
            let generation = row.string(3)
            let status: SessionStatus
            if header.hasBlockingPendingActions == true || header.hasPendingPlan == true {
                status = .needsInput
            } else if generation == "generating" {
                status = .working
            } else if header.hasUnreadMessages == true || generation == "completed" {
                // A finished reply you have read stays in Review, marked read, instead of turning idle.
                status = .ready
            } else {
                status = .idle
            }
            let lastWrite = row.int64(4)
            let completion = generation == "completed" || status == .ready
                ? Self.milliseconds(lastWrite > 0 ? lastWrite : row.int64(1)) : nil
            return Session(
                id: "cursor:\(id)", source: .cursor, title: Self.displayTitle(header.name, fallback: "Cursor chat"),
                status: status, updatedAt: Self.milliseconds(row.int64(1)),
                route: Self.agentRoute(scheme: "cursor", authority: "anysphere.cursor-deeplink", path: "/agent", id: id),
                activityID: String(row.int64(1)),
                reviewedBySource: status == .ready && header.hasUnreadMessages != true ? true : nil,
                completedAt: completion
            )
        }
    }

    private func cursorCloudSessions(in database: ReadOnlyDatabase, since cutoff: Date) -> [Session] {
        let account = database.read("SELECT value FROM ItemTable WHERE key = 'glass.lastSignedInAuthId'") {
            $0.string(0)
        }.first
        guard let account, !account.isEmpty,
              let suffix = account.addingPercentEncoding(withAllowedCharacters: Self.componentCharacters)
        else { return [] }
        let key = "cloudAgentRepository.agents." + suffix
        let query = "SELECT value FROM ItemTable WHERE key = ?1 AND length(value) <= 4000000"
        let rows = database.read(query, bind: {
            sqlite3_bind_text($0, 1, key, -1, ReadOnlyDatabase.transient)
        }) { row -> [CursorCloudRow]? in
            guard let data = row.data(0) else { return nil }
            return try? JSONDecoder().decode([CursorCloudRow].self, from: data)
        }.first ?? []
        return rows.compactMap { row in
            guard Self.validAgentID(row.bcId), row.isArchived != true, row.isKilled != true,
                  row.workflowStatus != 4, row.workflowStatus != 5 else { return nil }
            let stamp = max(row.lastMessageActivityAtMs ?? 0, row.updatedAt ?? 0, row.createdAt ?? 0)
            let updatedAt = Self.milliseconds(stamp)
            guard updatedAt >= cutoff else { return nil }
            let status: SessionStatus
            if row.hasPendingInteraction == true {
                status = .needsInput
            } else if [1, 6, 7].contains(row.workflowStatus ?? 0) ||
                        ((row.workflowStatus ?? 0) == 0 && [1, 4].contains(row.status ?? 0)) {
                status = .working
            } else if row.isUnread == true || [2, 3].contains(row.workflowStatus ?? 0)
                        || ((row.workflowStatus ?? 0) == 0 && [2, 3].contains(row.status ?? 0)) {
                // Finished or failed runs stay in Review once read, marked read, instead of turning idle.
                status = .ready
            } else {
                status = .idle
            }
            return Session(
                id: "cursor:\(row.bcId)", source: .cursor, title: Self.displayTitle(row.name, fallback: "Cursor cloud agent"),
                detail: "Cloud agent", status: status, updatedAt: updatedAt,
                route: Self.agentRoute(scheme: "cursor", authority: "anysphere.cursor-deeplink", path: "/background-agent", id: row.bcId, queryName: "bcId"),
                activityID: String(row.lastMessageActivityAtMs ?? stamp),
                reviewedBySource: status == .ready && row.isUnread != true ? true : nil,
                completedAt: status == .ready ? Self.milliseconds(row.lastMessageActivityAtMs ?? stamp) : nil
            )
        }
    }

    private func grokSessions(since cutoff: Date) -> [Session] {
        let root = home.appending(path: "Library/Application Support/Grok Bot/sand-client-persistence")
        // Read the roster identified by Grok Bot's account pointer.
        let slotURL = root.appending(path: Self.grokBlobName("sand.client.slice.client-meta.account-slot"))
        guard let slot: GrokEnvelope<String> = Self.decodeBlob(at: slotURL, maximumSize: 4096),
              !slot.value.isEmpty,
              let account = slot.value.addingPercentEncoding(withAllowedCharacters: Self.componentCharacters)
        else {
            grokRosterURL = nil
            grokRosterStamp = nil
            grokRows = []
            grokAgents = []
            return []
        }
        let url = root.appending(path: Self.grokBlobName("sand.client.slice.account.\(account).roster.last-roster"))
        guard let stamp = FileStamp(url: url) else { return [] }
        if stamp != grokRosterStamp || url != grokRosterURL {
            if let roster: GrokEnvelope<GrokRoster> = Self.decodeBlob(at: url, maximumSize: 2_000_000) {
                grokRows = roster.value.rows
                grokAgents = grokRows.compactMap { row in
                    guard Self.validAgentID(row.id), row.isHiddenFromSidebar != true,
                          row.isRemovedFromSidebar != true else { return nil }
                    return GrokAgent(id: "grok:\(row.id)", title: Self.displayTitle(
                        row.name, fallback: Self.displayTitle(row.title, fallback: "Grok Bot chat")))
                }
                grokRosterURL = url
                grokRosterStamp = stamp
            }
        }
        guard grokRosterURL == url else { return [] }
        let now = Date()
        let prefix = "sand.client.slice.account.\(account)."
        return grokRows.compactMap { row in
            guard Self.validAgentID(row.id), row.isHiddenFromSidebar != true, row.isRemovedFromSidebar != true else { return nil }
            let activity = max(row.localActivityAt ?? 0, row.lastActivityAt ?? 0)
            let updatedAt = Self.milliseconds(activity > 0 ? activity : (row.createdAt ?? 0))
            guard updatedAt >= cutoff else { return nil }
            // Grok Bot keeps no running flag on disk, so read the end of a recently active transcript.
            let tail = now.timeIntervalSince(updatedAt) < Self.grokTailWindow
                ? grokTail(at: root.appending(path: Self.grokBlobName(prefix + "transcript.replicas." + row.id)), id: row.id)
                : nil
            let unread = row.hasUnread == true || (row.unreadCount ?? 0) > 0 || (row.unreadThreadCount ?? 0) > 0
            let status = Self.grokStatus(
                awaitingInput: row.awaitingUserResponse != nil, unread: unread,
                agentRepliedLast: tail.map { !$0.fromUser } ?? Self.grokAgentSpokeLast(row.newestEntryId ?? row.lastMessageId),
                tail: tail, now: now)
            return Session(
                id: "grok:\(row.id)", source: .grok,
                title: Self.displayTitle(row.name, fallback: Self.displayTitle(row.title, fallback: "Grok Bot chat")),
                status: status, updatedAt: updatedAt,
                route: Self.agentRoute(scheme: "grokbot", authority: "app", path: "/v1/agent", id: row.id),
                activityID: row.awaitingUserResponse?.since.map(String.init) ?? row.newestEntryId ?? row.lastMessageId,
                // Grok Bot knows whether you read the reply, so a read one stays in Review without a dot.
                reviewedBySource: status == .ready && !unread ? true : nil,
                completedAt: status == .ready ? updatedAt : nil
            )
        }
    }

    /// How long a sent message counts as the agent working on it, and how long a progress note does.
    // Grok Bot records no running flag, so Working is read from the end of the transcript. The windows
    // come from measured turns: a request from you got its first answer within 3 minutes every time and
    // one from another agent within 15; after a message that looks like progress, more followed in 85%
    // of cases and almost never after 5 silent minutes; after any other message, more followed in 48%
    // of cases, mostly within seconds, and in 16% once 20 seconds had passed.
    static let grokTailWindow: TimeInterval = 30 * 60
    static let grokRequestWindow: TimeInterval = 10 * 60
    static let grokAgentRequestWindow: TimeInterval = 15 * 60
    static let grokProgressWindow: TimeInterval = 5 * 60
    static let grokSettleWindow: TimeInterval = 20

    /// Grok Bot names your messages "t<turn>u"; the agent's carry a sequence number or an outbound ID.
    static func grokAgentSpokeLast(_ entryID: String?) -> Bool {
        guard let entryID, !entryID.isEmpty else { return false }
        return entryID.range(of: #"\At[0-9]+u\z"#, options: .regularExpression) == nil
    }

    static func grokStatus(awaitingInput: Bool, unread: Bool, agentRepliedLast: Bool, tail: GrokTail?,
                           now: Date) -> SessionStatus {
        if awaitingInput { return .needsInput }
        if let tail {
            let age = now.timeIntervalSince(tail.date)
            if tail.isStreaming && age < grokAgentRequestWindow { return .working }
            let window: TimeInterval
            if tail.fromUser {
                // A request waits for its first answer.
                window = tail.fromAgent ? grokAgentRequestWindow : grokRequestWindow
            } else if tail.answeredWidget {
                // You answered the agent's question, so it owes you the next message.
                window = grokRequestWindow
            } else {
                // Agents usually send several messages in a row, so the newest one is not yet the last.
                window = looksLikeProgress(tail) ? grokProgressWindow : grokSettleWindow
            }
            if age < window { return .working }
        }
        // A reply you have read is still finished work: it stays in Review until you archive it.
        return unread || agentRepliedLast ? .ready : .idle
    }

    /// True for a message that is probably not the agent's last: a short first reply to a request,
    /// in any language, or wording that promises more.
    static func looksLikeProgress(_ tail: GrokTail) -> Bool {
        guard !tail.fromUser, let text = tail.text else { return false }
        return (tail.opensReply && text.count <= 300) || soundsInProgress(text)
    }

    /// True for an interim note that promises more, not for a final answer. The promise can open any
    /// sentence and often follows a short lead-in: "Great, I'll create…", "Hi Sam! I'm starting…".
    static func soundsInProgress(_ text: String) -> Bool {
        let text = text.lowercased().replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 600 else { return false }
        let openings = ["i'm ", "i am ", "i'll ", "i will ", "let me ", "working on", "looking into", "checking ",
                        "searching ", "digging ", "pulling ", "moving ", "on it", "one moment", "give me a",
                        "hang tight", "starting ", "kicking off", "running "]
        for sentence in sentences(in: text) {
            if openings.contains(where: sentence.hasPrefix) { return true }
            if let comma = sentence.range(of: ", "),
               sentence.distance(from: sentence.startIndex, to: comma.lowerBound) <= 14,
               openings.contains(where: sentence[comma.upperBound...].hasPrefix) { return true }
        }
        let markers = ["is running", "still running", "will take a few", "take a few minutes", "in the background",
                       "i'll send", "i'll follow up", "i'll let you know", "get back to you", "be right back",
                       "still working"]
        return markers.contains(where: text.contains)
    }

    /// Splits at sentence punctuation followed by a space, and at line breaks.
    private static func sentences(in text: String) -> [Substring] {
        var sentences: [Substring] = []
        var start = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            let character = text[index]
            if character.isNewline || (".!?:;".contains(character) && (next == text.endIndex || text[next].isWhitespace)) {
                let sentence = text[start..<next].drop(while: \.isWhitespace)
                if !sentence.isEmpty { sentences.append(sentence) }
                start = next
            }
            index = next
        }
        let rest = text[start...].drop(while: \.isWhitespace)
        if !rest.isEmpty { sentences.append(rest) }
        return sentences
    }

    private func grokTail(at url: URL, id: String) -> GrokTail? {
        guard let stamp = FileStamp(url: url) else { return nil }
        if let cached = grokTails[id], cached.stamp == stamp { return cached.tail }
        guard let transcript: GrokEnvelope<GrokTranscriptTail> = Self.decodeBlob(at: url, maximumSize: 4_000_000)
        else { return nil }
        let messages = transcript.value.entries.filter { $0.kind == "message" || $0.kind == "send-message" }
        guard let last = messages.last, let timestamp = last.timestampMs else { return nil }
        let fromUser = last.isRequest
        // An agent message opens the reply when the message before it is the request it answers, or a
        // question the agent put to you: answering a widget adds no message of yours to the transcript.
        let previous = messages.dropLast().last
        let opensReply = !fromUser && (previous?.isRequest == true || previous?.isWidget == true)
        let tail = GrokTail(fromUser: fromUser, text: last.message?.content ?? last.content,
                            date: Self.milliseconds(timestamp), fromAgent: fromUser && last.fromAgent,
                            opensReply: opensReply, isStreaming: last.isStreaming,
                            answeredWidget: last.isWidget && last.wasAnswered)
        grokTails[id] = (stamp, tail)
        return tail
    }

    private func instinctSession() -> [Session] {
        guard let recipient = Self.normalizedRecipient(defaults.string(forKey: "instinctRecipient") ?? "") else { return [] }
        var link = URLComponents()
        link.scheme = "messages"
        link.host = "open"
        link.queryItems = [URLQueryItem(name: "addresses", value: recipient)]
        // URLComponents leaves literal "+" in query values, where the handler may read it as a space.
        link.percentEncodedQuery = link.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let address = link.url?.absoluteString else { return [] }

        let url = home.appending(path: "Library/Messages/chat.db")
        let database = ReadOnlyDatabase(url)
        let newest = database.flatMap { newestInstinctMessage(in: $0, for: recipient) }
        let status: SessionStatus
        let detail: String
        if let newest {
            if newest.fromMe {
                status = .idle
                detail = "Waiting for reply"
            } else {
                status = .ready
                detail = "Messages"
            }
        } else {
            status = .unknown
            detail = database == nil ? "Reply tracking needs Full Disk Access" : "No matching one-to-one Messages chat"
        }
        return [Session(
            id: Self.instinctID(recipient), source: .instinct, title: "Instinct", detail: detail,
            status: status, updatedAt: newest?.date ?? .distantPast, route: .url(address),
            activityID: newest.map { String($0.id) },
            reviewedBySource: newest.flatMap { $0.fromMe ? nil : !$0.unread },
            completedAt: newest?.lastIncoming
        )]
    }

    private func newestInstinctMessage(in database: ReadOnlyDatabase, for recipient: String) -> MessageMetadata? {
        // Match a one-to-one chat by its handle and select only its newest message's delivery metadata.
        // Apple dates may use seconds or nanoseconds since 2001.
        let query = """
        SELECT m.date, m.is_from_me, m.is_read, m.ROWID,
               MAX(CASE WHEN m.is_from_me = 0 THEN m.date END) OVER ()
        FROM handle AS h
        JOIN chat_handle_join AS ch ON ch.handle_id = h.ROWID
        JOIN chat_message_join AS cm ON cm.chat_id = ch.chat_id
        JOIN message AS m ON m.ROWID = cm.message_id
        WHERE (h.id = ?1 COLLATE NOCASE OR h.id = ?2)
          AND (SELECT COUNT(*) FROM chat_handle_join AS participants WHERE participants.chat_id = ch.chat_id) = 1
          AND m.date > 0 AND COALESCE(m.associated_message_type, 0) = 0
        ORDER BY m.date DESC, m.ROWID DESC
        LIMIT 1
        """
        let alternate = recipient.contains("@") ? recipient :
            (recipient.hasPrefix("+") ? String(recipient.dropFirst()) : "+" + recipient)
        return database.read(query, bind: { statement in
            sqlite3_bind_text(statement, 1, recipient, -1, ReadOnlyDatabase.transient)
            sqlite3_bind_text(statement, 2, alternate, -1, ReadOnlyDatabase.transient)
        }) { row -> MessageMetadata? in
            guard let date = Self.messagesDate(row.int64(0)) else { return nil }
            return MessageMetadata(
                id: row.int64(3), date: date, fromMe: row.int64(1) == 1, unread: row.int64(2) == 0,
                lastIncoming: Self.messagesDate(row.int64(4))
            )
        }.first
    }

    private static func messagesDate(_ raw: Int64) -> Date? {
        guard raw > 0 else { return nil }
        let seconds = raw > 1_000_000_000_000 ? Double(raw) / 1_000_000_000 : Double(raw)
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    private static func instinctID(_ recipient: String) -> String {
        let digest = SHA256.hash(data: Data(recipient.lowercased().utf8))
        return "instinct:" + digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    static func normalizedRecipient(_ input: String) -> String? {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.contains("@") {
            guard input.count <= 254,
                  input.range(of: #"\A[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\z"#, options: .regularExpression) != nil
            else { return nil }
            return input
        }
        let punctuation = CharacterSet(charactersIn: " ()-.")
        let number = input.unicodeScalars.filter { !punctuation.contains($0) }.map(String.init).joined()
        guard number.range(of: #"\A\+?[0-9]{5,15}\z"#, options: .regularExpression) != nil else { return nil }
        return number
    }

    private static func milliseconds(_ value: Int64) -> Date {
        Date(timeIntervalSince1970: Double(value) / 1000)
    }

    private static func displayTitle(_ title: String?, fallback: String) -> String {
        let clean = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return clean.isEmpty ? fallback : String(clean.prefix(180))
    }

    static let componentCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")

    private static func validAgentID(_ id: String) -> Bool {
        id.count <= 128 && id.range(of: #"\A[A-Za-z0-9_-]+\z"#, options: .regularExpression) != nil
    }

    private static func agentRoute(scheme: String, authority: String, path: String, id: String, queryName: String = "id") -> Route {
        // The ID is restricted to URL-safe characters by validAgentID.
        .url("\(scheme)://\(authority)\(path)?\(queryName)=\(id)")
    }

    static func grokBlobName(_ key: String) -> String {
        // Grok Bot names cache files using lowercase, unpadded RFC 4648 Base32.
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567".utf8)
        var output: [UInt8] = []
        var accumulator = 0
        var bits = 0
        for byte in key.utf8 {
            accumulator = (accumulator << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                output.append(alphabet[(accumulator >> bits) & 31])
            }
            accumulator &= (1 << bits) - 1
        }
        if bits > 0 {
            output.append(alphabet[(accumulator << (5 - bits)) & 31])
        }
        return String(decoding: output, as: UTF8.self) + ".blob"
    }

    private static func decodeBlob<T: Decodable>(at url: URL, maximumSize: Int) -> T? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maximumSize,
              let data = try? Data(contentsOf: url), data.count <= maximumSize
        else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

private struct CursorHeader: Decodable {
    let name: String?
    let isDraft: Bool?
    let hasBlockingPendingActions: Bool?
    let hasPendingPlan: Bool?
    let hasUnreadMessages: Bool?
}

private struct CursorCloudRow: Decodable {
    let bcId: String
    let name: String?
    let status: Int?
    let workflowStatus: Int?
    let isUnread: Bool?
    let hasPendingInteraction: Bool?
    let isArchived: Bool?
    let isKilled: Bool?
    let lastMessageActivityAtMs: Int64?
    let updatedAt: Int64?
    let createdAt: Int64?
}

/// The newest message in a Grok Bot transcript.
/// The newest message in a Grok Bot transcript and how it sits in its turn.
struct GrokTail: Equatable {
    /// True when the newest message is a request, from you or from another agent.
    let fromUser: Bool
    let text: String?
    let date: Date
    /// For a request: another agent sent it, not you.
    var fromAgent = false
    /// For an agent message: it is the first one since the request it answers.
    var opensReply = false
    /// Grok Bot is still writing this message.
    var isStreaming = false
    /// The newest message is a question from the agent that you have already answered.
    var answeredWidget = false
}

private struct GrokTranscriptTail: Decodable {
    let entries: [Entry]

    struct Entry: Decodable {
        struct Outgoing: Decodable {
            let content: String?
            let type: String?
            init(from decoder: Decoder) throws {
                let fields = try? decoder.container(keyedBy: CodingKeys.self)
                content = try? fields?.decodeIfPresent(String.self, forKey: .content)
                type = try? fields?.decodeIfPresent(String.self, forKey: .type)
            }
            private enum CodingKeys: String, CodingKey { case content, type }
        }

        let kind: String
        let role: String?
        let content: String?
        let message: Outgoing?
        let timestampMs: Int64?
        let isStreaming: Bool
        /// Requests from other agents carry a fromAgent object; yours do not.
        let fromAgent: Bool

        /// You answered this widget. The answer is stored on the widget, not as a message of yours.
        let wasAnswered: Bool

        /// A message the agent has to answer: yours, or one another agent sent it.
        var isRequest: Bool { kind == "message" && role == "user" }
        /// A question or approval the agent put to you.
        var isWidget: Bool { kind == "send-message" && (message?.type == "widget" || message?.type == "auto-review-approval") }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            kind = (try? fields.decode(String.self, forKey: .kind)) ?? ""
            role = try? fields.decodeIfPresent(String.self, forKey: .role)
            content = try? fields.decodeIfPresent(String.self, forKey: .content)
            message = try? fields.decodeIfPresent(Outgoing.self, forKey: .message)
            timestampMs = try? fields.decodeIfPresent(Int64.self, forKey: .timestampMs)
            isStreaming = (try? fields.decodeIfPresent(Bool.self, forKey: .isStreaming)) == true
            fromAgent = fields.contains(.fromAgent) && (try? fields.decodeNil(forKey: .fromAgent)) != true
            wasAnswered = fields.contains(.respondedValue) && (try? fields.decodeNil(forKey: .respondedValue)) != true
        }

        private enum CodingKeys: String, CodingKey {
            case kind, role, content, message, timestampMs, isStreaming, fromAgent, respondedValue
        }
    }
}

private struct GrokEnvelope<Value: Decodable>: Decodable {
    let value: Value
}

private struct GrokRoster: Decodable {
    let rows: [GrokRow]
}

private struct GrokRow: Decodable {
    let id: String
    let name: String?
    let title: String?
    let isHiddenFromSidebar: Bool?
    let isRemovedFromSidebar: Bool?
    let hasUnread: Bool?
    let unreadCount: Int?
    let unreadThreadCount: Int?
    let awaitingUserResponse: AwaitingResponse?
    let createdAt: Int64?
    let lastActivityAt: Int64?
    let localActivityAt: Int64?
    let lastMessageId: String?
    let newestEntryId: String?

    struct AwaitingResponse: Decodable {
        let since: Int64?

        init(from decoder: Decoder) throws {
            let container = try? decoder.container(keyedBy: CodingKeys.self)
            since = try? container?.decodeIfPresent(Int64.self, forKey: .since)
        }

        private enum CodingKeys: String, CodingKey { case since }
    }
}

private struct FileStamp: Equatable {
    let modified: Date
    let size: Int

    init?(url: URL) {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let modified = values.contentModificationDate, let size = values.fileSize else { return nil }
        self.modified = modified
        self.size = size
    }
}

private struct MessageMetadata {
    let id: Int64
    let date: Date
    let fromMe: Bool
    let unread: Bool
    let lastIncoming: Date?
}

private final class ReadOnlyDatabase {
    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let handle: OpaquePointer

    init?(_ url: URL) {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let database else {
            sqlite3_close(database)
            return nil
        }
        handle = database
        sqlite3_busy_timeout(database, 60)
    }

    deinit {
        sqlite3_close(handle)
    }

    func read<Value>(
        _ query: String,
        bind: (OpaquePointer) -> Void = { _ in },
        map: (Row) -> Value?
    ) -> [Value] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, query, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            sqlite3_finalize(statement)
            return []
        }
        defer { sqlite3_finalize(statement) }
        bind(statement)
        var result: [Value] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = map(Row(statement: statement)) {
                result.append(value)
            }
        }
        return result
    }

    struct Row {
        fileprivate let statement: OpaquePointer

        func string(_ index: Int32) -> String? {
            sqlite3_column_text(statement, index).map { String(cString: $0) }
        }

        func data(_ index: Int32) -> Data? {
            guard let bytes = sqlite3_column_blob(statement, index) else { return nil }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
        }

        func int64(_ index: Int32) -> Int64 {
            sqlite3_column_int64(statement, index)
        }
    }
}
