import Darwin
import Foundation
import SQLite3

final class CodexProvider: @unchecked Sendable {
    private let home: URL
    private let runtime: CodexRuntimeMonitor
    private var lastScan: [Session] = []

    init(home: URL = CodexProvider.defaultHome) {
        self.home = home
        runtime = CodexRuntimeMonitor(socketURL: home.appendingPathComponent("ipc/ipc.sock"))
    }

    static var defaultHome: URL {
        if let path = ProcessInfo.processInfo.environment["CODEX_HOME"], path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    }

    // The desktop has its own app-server connection. Read its indexed local projection
    // so Relay can discover chats without opening, resuming, or writing to any of them.
    func scan(includeAutomationRuns: Bool = false) -> [Session] {
        let now = Date()
        guard let state = database("state", current: 5) else {
            runtime.update(workingThreads: [], now: now)
            lastScan = []
            return []
        }
        if let sessions = readSessions(state: state, now: now, includeAutomationRuns: includeAutomationRuns) {
            let workingThreads = Set(sessions.filter { $0.status == .working }.map(threadID))
            runtime.update(workingThreads: workingThreads, now: now)
            lastScan = sessions.map { session in
                guard session.status == .working, let waitingSince = runtime.waitingSince(threadID(session)) else {
                    return session
                }
                return Session(
                    id: session.id, source: session.source, title: session.title, detail: session.detail,
                    status: .needsInput, updatedAt: waitingSince, route: session.route,
                    activityID: (session.activityID ?? "") + ":input:\(waitingSince.timeIntervalSince1970)",
                    completedAt: session.completedAt, isAutomationRun: session.isAutomationRun
                )
            }
        }
        return lastScan
    }

    func suspend() {
        runtime.update(workingThreads: [], now: Date())
        lastScan = []
    }

    private func threadID(_ session: Session) -> String {
        String(session.id.dropFirst("codex:".count))
    }

    private func readSessions(state: URL, now: Date, includeAutomationRuns: Bool) -> [Session]? {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(
            state.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil
        )
        defer { sqlite3_close(database) }
        guard result == SQLITE_OK, let database else { return nil }
        sqlite3_busy_timeout(database, 30)
        sqlite3_exec(database, "PRAGMA query_only = ON", nil, nil, nil)

        let columns = threadColumns(in: database)
        guard columns.isSuperset(of: ["id", "source", "title", "cwd", "updated_at", "archived"]) else {
            return nil
        }

        let hasHistory = attach(self.database("thread_history", current: 1), as: "history", to: database) &&
            canPrepare("""
                SELECT thread_id, turn_id, rollout_ordinal, status, started_at, completed_at
                FROM history.thread_turns LIMIT 0
                """, in: database)
        let hasScheduleDatabase = attach(home.appendingPathComponent("sqlite/codex.db"),
                                         as: "schedules", to: database)
        let standaloneRun = hasScheduleDatabase && canPrepare(
            "SELECT thread_id FROM schedules.automation_runs LIMIT 0", in: database
        ) ? "EXISTS (SELECT 1 FROM schedules.automation_runs AS run WHERE run.thread_id = t.id)" : "0"
        let hasHeartbeat = hasHistory && hasScheduleDatabase && canPrepare(
            "SELECT target_thread_id, kind, last_run_at FROM schedules.automations LIMIT 0", in: database
        )
        let hasFirstItem = hasHistory && canPrepare("""
            SELECT turn.first_user_item_id, item.thread_id, item.turn_id, item.item_id, item.item_type,
                   json_extract(item.item_json, '$.content[0].text')
            FROM history.thread_turns AS turn, history.thread_items AS item LIMIT 0
            """, in: database)
        let scheduledStart = hasHeartbeat ? """
            EXISTS (
                SELECT 1 FROM schedules.automations AS automation
                WHERE automation.kind = 'heartbeat' AND automation.target_thread_id = t.id
                  AND CAST(automation.last_run_at / 1000 AS INTEGER) = turn.started_at
            )
            """ : "0"
        let heartbeatEnvelope = """
            ('<heartbeat>' || char(10) || '  <automation_id>?*</automation_id>' || char(10) ||
             '  <current_time_iso>????-??-??T??:??:??*Z</current_time_iso>' || char(10) ||
             '  <instructions>' || char(10) || '*' || char(10) || '  </instructions>' ||
             char(10) || '</heartbeat>')
            """
        // A heartbeat can run in a regular chat. Check the latest turn's native
        // envelope, with a timestamp fallback when the first item is unavailable.
        let heartbeat = hasFirstItem ? """
            COALESCE((
                SELECT CASE WHEN json_valid(item.item_json) THEN COALESCE(
                    json_extract(item.item_json, '$.content[0].type') = 'text'
                    AND rtrim(json_extract(item.item_json, '$.content[0].text'), char(10) || char(13))
                        GLOB \(heartbeatEnvelope),
                    0) END
                FROM history.thread_items AS item
                WHERE item.thread_id = turn.thread_id AND item.turn_id = turn.turn_id
                  AND item.item_id = turn.first_user_item_id AND item.item_type = 'userMessage'
            ), (\(scheduledStart)))
            """ : scheduledStart
        let automationRun = "(\(standaloneRun) OR \(heartbeat))"
        let recency = columns.contains("recency_at_ms") ? "t.recency_at_ms" : "t.updated_at * 1000"
        let name = columns.contains("name") ? "COALESCE(NULLIF(t.name, ''), t.title)" : "t.title"
        let source = columns.contains("thread_source")
            ? "AND (t.thread_source IS NULL OR t.thread_source IN ('user', 'chatgpt_handoff') OR \(standaloneRun))" : ""
        let attached = columns.contains("attached_thread_parent_id") ? "AND t.attached_thread_parent_id IS NULL" : ""
        let visible = columns.contains("preview") ? "AND t.preview <> ''" : "AND t.title <> ''"
        let turn = hasHistory ? "turn.turn_id, turn.status, turn.started_at, turn.completed_at" : "NULL, NULL, NULL, NULL"
        let historyJoin = hasHistory ? """
            LEFT JOIN history.thread_turns AS turn ON turn.thread_id = t.id AND turn.rollout_ordinal = (
                SELECT rollout_ordinal FROM history.thread_turns
                WHERE thread_id = t.id ORDER BY rollout_ordinal DESC LIMIT 1
            )
            """ : ""
        let lastCompletion = hasHistory ? """
            (SELECT MAX(completed_at) FROM history.thread_turns
             WHERE thread_id = t.id AND status = 'completed')
            """ : "NULL"
        let hasReadReceipts = hasHistory && canPrepare(
            "SELECT thread_id, first_unread_turn, last_published_turn FROM thread_read_receipts LIMIT 0",
            in: database
        )
        let reviewed = hasReadReceipts ? """
            CASE WHEN receipt.first_unread_turn IS NOT NULL THEN 0
                 WHEN receipt.last_published_turn = turn.turn_id THEN 1 END
            """ : "NULL"
        let receiptsJoin = hasReadReceipts
            ? "LEFT JOIN thread_read_receipts AS receipt ON receipt.thread_id = t.id" : ""
        let sql = """
            SELECT t.id, \(name), t.cwd, \(recency), t.updated_at,
                   \(turn), \(reviewed), \(lastCompletion), \(automationRun)
            FROM threads AS t
            \(historyJoin)
            \(receiptsJoin)
            WHERE t.archived = 0 AND (t.source = 'vscode' OR \(standaloneRun)) AND \(recency) >= ?
                  \(source) \(attached) \(visible)
                  AND (? OR NOT \(automationRun))
            ORDER BY \(recency) DESC, t.id DESC
            LIMIT 32
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        sqlite3_bind_int64(statement, 1, Int64(now.addingTimeInterval(-24 * 60 * 60).timeIntervalSince1970 * 1000))
        sqlite3_bind_int(statement, 2, includeAutomationRuns ? 1 : 0)

        var sessions: [Session] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            if let session = session(from: statement, now: now) {
                sessions.append(session)
            }
            step = sqlite3_step(statement)
        }
        return step == SQLITE_DONE ? sessions : nil
    }

    private func session(from row: OpaquePointer, now: Date) -> Session? {
        guard let id = text(row, 0), UUID(uuidString: id) != nil else { return nil }
        let recency = Date(timeIntervalSince1970: Double(sqlite3_column_int64(row, 3)) / 1000)
        let updated = Date(timeIntervalSince1970: Double(sqlite3_column_int64(row, 4)))
        let activity = text(row, 5)
        let started = timestamp(row, 7)
        let completed = timestamp(row, 8)
        let status: SessionStatus
        let activityDate: Date

        switch text(row, 6) {
        case "inProgress":
            status = writerIsActive(id) || updated >= now.addingTimeInterval(-10) ? .working : .unknown
            activityDate = started ?? recency
        case "completed", "failed":
            status = .ready
            activityDate = completed ?? updated
        case "interrupted":
            status = .idle
            activityDate = completed ?? updated
        default:
            status = .unknown
            activityDate = recency
        }

        let title = text(row, 1)?.prefix(160).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let reviewed = status == .ready && sqlite3_column_type(row, 9) != SQLITE_NULL
            ? sqlite3_column_int(row, 9) != 0 : nil
        return Session(
            id: "codex:" + id.lowercased(), source: .codex,
            title: title.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled chat",
            detail: workspaceName(text(row, 2)), status: status, updatedAt: activityDate,
            route: .url("codex://threads/" + id.lowercased()), activityID: activity,
            reviewedBySource: reviewed, completedAt: timestamp(row, 10),
            isAutomationRun: sqlite3_column_int(row, 11) != 0
        )
    }

    private func workspaceName(_ path: String?) -> String {
        guard let path, path.hasPrefix("/") else { return "" }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let userHome = FileManager.default.homeDirectoryForCurrentUser
        let chatFolder = userHome.appendingPathComponent("Documents/Codex", isDirectory: true).path
        if url.path == userHome.path || url.path.hasPrefix(chatFolder + "/") { return "" }
        return url.lastPathComponent
    }

    private func writerIsActive(_ id: String) -> Bool {
        let path = home.appendingPathComponent("thread-writer-locks/\(id).lock").path
        let file = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { return false }
        defer { close(file) }
        // Test whether the existing writer holds its lock without taking an exclusive lock.
        return flock(file, LOCK_SH | LOCK_NB) != 0 && errno == EWOULDBLOCK
    }

    private func database(_ stem: String, current: Int) -> URL? {
        let files = FileManager.default
        let preferred = home.appendingPathComponent("\(stem)_\(current).sqlite")
        if files.fileExists(atPath: preferred.path) { return preferred }
        let entries = try? files.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)
        let prefix = stem + "_"
        return entries?.compactMap { url -> (Int, URL)? in
            guard url.pathExtension == "sqlite" else { return nil }
            let name = url.deletingPathExtension().lastPathComponent
            guard name.hasPrefix(prefix), let version = Int(name.dropFirst(prefix.count)) else { return nil }
            return (version, url)
        }.max { $0.0 < $1.0 }?.1
    }

    private func threadColumns(in database: OpaquePointer) -> Set<String> {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(threads)", -1, &statement, nil) == SQLITE_OK,
              let statement else { return [] }
        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = text(statement, 1) { columns.insert(name) }
        }
        return columns
    }

    private func canPrepare(_ sql: String, in database: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        return sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK
    }

    private func attach(_ url: URL?, as schema: String, to database: OpaquePointer) -> Bool {
        guard let url else { return false }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "ATTACH DATABASE ? AS " + schema, -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        let path = url.absoluteString + "?mode=ro"
        return path.withCString { bytes in
            sqlite3_bind_text(statement, 1, bytes, -1, nil) == SQLITE_OK &&
                sqlite3_step(statement) == SQLITE_DONE
        }
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }

    private func timestamp(_ statement: OpaquePointer, _ column: Int32) -> Date? {
        let value = sqlite3_column_int64(statement, column)
        return value > 0 ? Date(timeIntervalSince1970: Double(value)) : nil
    }
}

// The desktop broadcasts runtime state to chat followers. Use its optional local
// socket only for live input flags. Turn discovery and completion work without it.
private final class CodexRuntimeMonitor {
    private struct RuntimeStatus: Decodable {
        var type: String?
        var activeFlags: [String]?

        var isWaiting: Bool {
            type == "active" && activeFlags?.contains {
                $0 == "waitingOnApproval" || $0 == "waitingOnUserInput"
            } == true
        }
    }

    private struct StatePatch: Decodable {
        let appliesToStatus: Bool
        let field: String?
        let index: Int?
        let op: String
        var status: RuntimeStatus?
        var flags: [String]?
        var value: String?

        private enum CodingKeys: String, CodingKey { case path, op, value }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            op = try values.decode(String.self, forKey: .op)
            var path = try values.nestedUnkeyedContainer(forKey: .path)
            appliesToStatus = (try? path.decode(String.self)) == "threadRuntimeStatus"
            field = appliesToStatus ? try? path.decode(String.self) : nil
            index = field == "activeFlags" ? try? path.decode(Int.self) : nil
            guard appliesToStatus else { return }
            switch field {
            case nil: status = try? values.decode(RuntimeStatus.self, forKey: .value)
            case "activeFlags" where index == nil: flags = try? values.decode([String].self, forKey: .value)
            default: value = try? values.decode(String.self, forKey: .value)
            }
        }
    }

    private struct Incoming: Decodable {
        struct Result: Decodable { let clientId: String? }
        struct Parameters: Decodable {
            struct Change: Decodable {
                struct State: Decodable { let threadRuntimeStatus: RuntimeStatus? }
                let type: String
                let conversationState: State?
                let patches: [StatePatch]?
            }
            let hostId: String?
            let conversationId: String?
            let clientId: String?
            let status: String?
            let change: Change?
        }
        let type: String
        let method: String?
        let requestId: String?
        let sourceClientId: String?
        let result: Result?
        let params: Parameters?
    }

    private struct Outgoing: Encodable {
        struct Parameters: Encodable {
            var clientType: String?
            var hostId: String?
            var conversationId: String?
            var following: Bool?
        }
        let type: String
        let method: String
        let sourceClientId: String
        let version: Int
        var requestId: String?
        let params: Parameters
    }

    private struct Evidence {
        let source: String
        var status: RuntimeStatus?
        var waitingSince: Date?
    }

    private let socketURL: URL
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private var descriptor: Int32 = -1
    private var connectionAttempt = Date.distantPast
    private var requestID: String?
    private var clientID: String?
    private var followed = Set<String>()
    private var evidence: [String: Evidence] = [:]
    private var buffer: [UInt8] = []
    private var bytesToSkip = 0

    init(socketURL: URL) { self.socketURL = socketURL }
    deinit { if descriptor >= 0 { close(descriptor) } }

    func waitingSince(_ id: String) -> Date? { evidence[id]?.waitingSince }

    func update(workingThreads: Set<String>, now: Date) {
        guard !workingThreads.isEmpty else {
            if descriptor >= 0 { disconnect() }
            return
        }
        if descriptor < 0 {
            guard now.timeIntervalSince(connectionAttempt) >= 5 else { return }
            connect(now: now)
        }
        guard descriptor >= 0 else { return }
        receive(now: now)
        guard let clientID, descriptor >= 0 else {
            if now.timeIntervalSince(connectionAttempt) >= 5 { disconnect() }
            return
        }

        for id in followed.subtracting(workingThreads) {
            guard setFollowing(false, id: id, clientID: clientID) else { return }
            followed.remove(id)
            evidence.removeValue(forKey: id)
        }
        for id in workingThreads.subtracting(followed) {
            guard setFollowing(true, id: id, clientID: clientID) else { return }
            followed.insert(id)
        }
    }

    private func connect(now: Date) {
        connectionAttempt = now
        let path = socketURL.path
        var metadata = stat()
        guard lstat(path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFSOCK, metadata.st_uid == geteuid() else { return }
        var address = sockaddr_un()
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size - MemoryLayout.size(ofValue: address.sun_path) + pathBytes.count)
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            pathBytes.withUnsafeBytes { target.copyBytes(from: $0) }
        }

        let file = socket(AF_UNIX, SOCK_STREAM, 0)
        guard file >= 0 else { return }
        var noSignal: Int32 = 1
        guard fcntl(file, F_SETFL, O_NONBLOCK) == 0,
              fcntl(file, F_SETFD, FD_CLOEXEC) == 0,
              setsockopt(file, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            close(file)
            return
        }
        let addressLength = socklen_t(address.sun_len)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(file, $0, addressLength)
            }
        }
        guard connected == 0 else { close(file); return }
        descriptor = file
        let id = UUID().uuidString
        requestID = id
        _ = send(Outgoing(
            type: "request", method: "initialize", sourceClientId: "initializing-client",
            version: 0, requestId: id, params: .init(clientType: "relay-session-monitor")
        ))
    }

    private func disconnect() {
        if descriptor >= 0 { close(descriptor) }
        descriptor = -1
        requestID = nil
        clientID = nil
        followed.removeAll()
        evidence.removeAll()
        buffer.removeAll()
        bytesToSkip = 0
    }

    private func setFollowing(_ value: Bool, id: String, clientID: String) -> Bool {
        send(Outgoing(
            type: "broadcast", method: "thread-stream-following-changed", sourceClientId: clientID,
            version: 1, params: .init(hostId: "local", conversationId: id, following: value)
        ))
    }

    private func send(_ message: Outgoing) -> Bool {
        guard let payload = try? encoder.encode(message), descriptor >= 0 else { return false }
        var size = UInt32(payload.count).littleEndian
        var frame = Data(bytes: &size, count: MemoryLayout<UInt32>.size)
        frame.append(payload)
        let sent = frame.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, $0.count, 0) }
        guard sent == frame.count else { disconnect(); return false }
        return true
    }

    private func receive(now: Date) {
        var scratch = [UInt8](repeating: 0, count: 32 * 1024)
        for _ in 0..<32 {
            let read = scratch.withUnsafeMutableBytes {
                recv(descriptor, $0.baseAddress, $0.count, 0)
            }
            if read > 0 {
                buffer.append(contentsOf: scratch.prefix(read))
            } else {
                if read == 0 || (errno != EWOULDBLOCK && errno != EINTR) {
                    disconnect()
                    return
                }
                break
            }
        }
        consumeFrames(now: now)
    }

    private func consumeFrames(now: Date) {
        var cursor = 0
        while cursor < buffer.count {
            if bytesToSkip > 0 {
                let consumed = min(bytesToSkip, buffer.count - cursor)
                cursor += consumed
                bytesToSkip -= consumed
                continue
            }
            guard buffer.count - cursor >= 4 else { break }
            let length = Int(buffer[cursor]) | Int(buffer[cursor + 1]) << 8 |
                Int(buffer[cursor + 2]) << 16 | Int(buffer[cursor + 3]) << 24
            if length > 4 * 1024 * 1024 {
                bytesToSkip = length
                cursor += 4
                evidence.removeAll()
                continue
            }
            let end = cursor + 4 + length
            guard end <= buffer.count else { break }
            if let message = try? decoder.decode(Incoming.self, from: Data(buffer[(cursor + 4)..<end])) {
                handle(message, now: now)
            }
            cursor = end
        }
        if cursor > 0 { buffer.removeFirst(cursor) }
    }

    private func handle(_ message: Incoming, now: Date) {
        if message.type == "response", message.requestId == requestID, let id = message.result?.clientId {
            clientID = id
            requestID = nil
            return
        }
        guard message.type == "broadcast", let params = message.params else { return }
        if message.method == "client-status-changed", params.status == "disconnected", let id = params.clientId {
            for thread in evidence.keys.filter({ evidence[$0]?.source == id }) {
                followed.remove(thread)
                evidence.removeValue(forKey: thread)
            }
            return
        }
        guard message.method == "thread-stream-state-changed", params.hostId == "local",
              let id = params.conversationId, followed.contains(id),
              let source = message.sourceClientId, let change = params.change else { return }

        let previous = evidence[id]
        let status: RuntimeStatus?
        switch change.type {
        case "snapshot":
            status = change.conversationState?.threadRuntimeStatus
        case "patches" where previous == nil || previous?.source == source:
            guard let patches = change.patches?.filter(\.appliesToStatus), !patches.isEmpty else { return }
            status = patches.reduce(previous?.status, apply)
        default:
            return
        }
        let waitingSince = status?.isWaiting == true ? previous?.waitingSince ?? now : nil
        evidence[id] = Evidence(source: source, status: status, waitingSince: waitingSince)
    }

    private func apply(_ current: RuntimeStatus?, _ patch: StatePatch) -> RuntimeStatus? {
        var status = current ?? RuntimeStatus()
        switch patch.field {
        case nil: return patch.status
        case "type": status.type = patch.value
        case "activeFlags":
            if let index = patch.index {
                var flags = status.activeFlags ?? []
                if patch.op == "add", index >= 0, index <= flags.count, let flag = patch.value {
                    flags.insert(flag, at: index)
                } else if flags.indices.contains(index) {
                    if patch.op == "remove" {
                        flags.remove(at: index)
                    } else if let flag = patch.value {
                        flags[index] = flag
                    }
                }
                status.activeFlags = flags
            } else {
                status.activeFlags = patch.flags
            }
        default: break
        }
        return status
    }
}
