import Foundation
import SQLite3

struct SessionEvidence: Sendable {
    var latestRequest: String?
    var latestOutcome: String?
    var pendingAction: String?
    var activityContext: String?
}

/// Reads bounded, session-scoped snapshots of local provider data. The caller owns their lifetime.
struct SessionEvidenceReader: Sendable {
    private let home: URL
    private let codexHome: URL
    private let claudeHome: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         codexHome: URL = CodexProvider.defaultHome) {
        self.home = home
        self.codexHome = codexHome
        if let path = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], path.hasPrefix("/") {
            claudeHome = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            claudeHome = home.appendingPathComponent(".claude", isDirectory: true)
        }
    }

    func read(_ session: Session, includeTranscript: Bool) -> SessionEvidence {
        switch session.source {
        case .codex: return codex(session, includeTranscript: includeTranscript)
        case .claude: return claude(session, includeTranscript: includeTranscript)
        case .cursor: return cursor(session, includeTranscript: includeTranscript)
        case .grok: return grok(session, includeTranscript: includeTranscript)
        }
    }

    private func codex(_ session: Session, includeTranscript: Bool) -> SessionEvidence {
        guard let thread = Self.id(session, prefix: "codex:"), UUID(uuidString: thread) != nil,
              let activity = session.activityID,
              let turn = activity.split(separator: ":").first.map(String.init),
              Self.validKey(turn) else { return SessionEvidence() }
        let database = codexHome.appendingPathComponent("thread_history_1.sqlite")
        let arguments = [thread, turn]
        let metadata = Self.query(database, """
            SELECT status, (
                SELECT substr(json_extract(item_json, '$.text'), 1, 6000)
                FROM thread_items
                WHERE thread_id = ?1 AND turn_id = ?2 AND item_type = 'plan'
                  AND length(item_json) < 150000 AND json_valid(item_json)
                ORDER BY rollout_ordinal DESC LIMIT 1
            )
            FROM thread_turns WHERE thread_id = ?1 AND turn_id = ?2 LIMIT 1
            """, arguments, columns: 2)
        var evidence = SessionEvidence()
        switch metadata[0] {
        case "failed": evidence.activityContext = "Codex reports that the latest turn failed."
        case "interrupted": evidence.activityContext = "Codex reports that the latest turn was interrupted."
        case "completed": evidence.activityContext = "Codex reports that the latest turn completed."
        default: break
        }
        if let plan = metadata[1] {
            evidence.pendingAction = plan.split(whereSeparator: \.isNewline).lazy
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("- [ ] ") || $0.hasPrefix("* [ ] ") }
                .compactMap { Self.clean(String($0.dropFirst(6)), limit: 360) }
                .first
        }
        guard includeTranscript else { return evidence }
        let messages = Self.query(database, """
            SELECT (
                SELECT substr(group_concat(substr(json_extract(part.value, '$.text'), 1, 1400), char(10)), 1, 1800)
                FROM thread_items AS input, json_each(input.item_json, '$.content') AS part
                WHERE input.thread_id = turns.thread_id AND input.turn_id = turns.turn_id
                  AND input.item_id = turns.first_user_item_id AND input.item_type = 'userMessage'
                  AND length(input.item_json) < 200000 AND json_valid(input.item_json)
                  AND part.type = 'object' AND json_extract(part.value, '$.type') = 'text'
            ), (
                SELECT substr(json_extract(output.item_json, '$.text'), -3600)
                FROM thread_items AS output
                WHERE output.thread_id = turns.thread_id AND output.turn_id = turns.turn_id
                  AND output.item_id = turns.final_agent_item_id AND output.item_type = 'agentMessage'
                  AND length(output.item_json) < 250000 AND json_valid(output.item_json)
                LIMIT 1
            )
            FROM thread_turns AS turns WHERE turns.thread_id = ?1 AND turns.turn_id = ?2 LIMIT 1
            """, arguments, columns: 2)
        evidence.latestRequest = Self.clean(messages[0], limit: 1250)
        if session.status == .working {
            if let progress = Self.clean(messages[1], limit: 500) {
                evidence.activityContext = "Codex’s latest progress message: " + progress
                return evidence
            }
        } else {
            evidence.latestOutcome = Self.clean(messages[1], limit: 2500)
        }
        if evidence.latestOutcome == nil && (session.status == .working || session.status == .needsInput) {
            let progress = Self.query(database, """
                SELECT substr(json_extract(item_json, '$.text'), 1, 650)
                FROM thread_items WHERE thread_id = ?1 AND turn_id = ?2
                  AND item_type = 'agentMessage' AND length(item_json) < 250000 AND json_valid(item_json)
                  AND json_extract(item_json, '$.phase') = 'commentary'
                ORDER BY rollout_ordinal DESC LIMIT 1
                """, arguments, columns: 1)[0]
            if let progress = Self.clean(progress, limit: 500) {
                evidence.activityContext = "Codex’s latest progress message: " + progress
            }
        }
        return evidence
    }

    private struct ClaudeDesktop: Decodable {
        struct Summary: Decodable {
            let needs_action: String?
            let status_detail: String?
            let summarizes_uuid: String?
        }
        let cwd: String?
        let originCwd: String?
        let cliSessionId: String?
        let lastAssistantCliSessionId: String?
        let lastAssistantUuid: String?
        let latestUserFrameAt: Int64?
        let lastTurnEdgeAt: Int64?
        let postTurnSummary: Summary?

        var currentSummary: Summary? {
            guard let summary = postTurnSummary, let lastAssistantUuid,
                  summary.summarizes_uuid == lastAssistantUuid else { return nil }
            if let latestUserFrameAt, let lastTurnEdgeAt, latestUserFrameAt > lastTurnEdgeAt { return nil }
            return summary
        }
    }

    private func claude(_ session: Session, includeTranscript: Bool) -> SessionEvidence {
        guard let id = Self.id(session, prefix: "claude:") else { return SessionEvidence() }
        let desktop: ClaudeDesktop?
        if id.hasPrefix("local_"), case .url = session.route {
            let root = home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
            desktop = Self.directories(root).prefix(12).lazy
                .flatMap { Self.directories($0).prefix(80) }
                .compactMap { folder in
                    Self.decode(ClaudeDesktop.self,
                                at: folder.appendingPathComponent(id).appendingPathExtension("json"),
                                limit: 2_000_000)
                }.first
        } else {
            desktop = nil
        }
        let summary = desktop?.currentSummary
        var evidence = SessionEvidence(
            latestOutcome: Self.clean(summary?.status_detail, limit: 500),
            pendingAction: Self.action(summary?.needs_action)
        )
        guard includeTranscript else { return evidence }

        let sessionIDs: [String]
        let folders: [String]
        switch session.route {
        case let .claude(sessionID, directory, _):
            sessionIDs = [sessionID]
            folders = [directory]
        case let .claudeBackground(_, directory):
            sessionIDs = [id]
            folders = [directory]
        case .url:
            guard let desktop else { return evidence }
            let active = desktop.cliSessionId ?? desktop.lastAssistantCliSessionId
            sessionIDs = active.map { [$0] } ?? []
            folders = [desktop.cwd, desktop.originCwd].compactMap { $0 }
        }
        let root = claudeHome.appendingPathComponent("projects")
        for sessionID in sessionIDs where UUID(uuidString: sessionID) != nil {
            for directory in folders where directory.hasPrefix("/") {
                let folder = directory.replacingOccurrences(of: #"[^A-Za-z0-9_-]"#, with: "-",
                                                             options: .regularExpression)
                let path = root.appendingPathComponent(folder).appendingPathComponent(sessionID)
                    .appendingPathExtension("jsonl")
                let pair = Self.claudeMessages(at: path, assistantID: desktop?.lastAssistantUuid,
                                               working: session.status == .working)
                if evidence.latestRequest == nil { evidence.latestRequest = pair.request }
                if let response = pair.response {
                    if session.status == .working {
                        evidence.activityContext = "Claude’s latest in-progress message: " + response
                    } else {
                        evidence.latestOutcome = response
                    }
                }
                if evidence.latestRequest != nil && pair.response != nil { return evidence }
            }
        }
        return evidence
    }

    private static func claudeMessages(at url: URL, assistantID: String?, working: Bool)
        -> (request: String?, response: String?) {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              let file = try? FileHandle(forReadingFrom: url) else { return (nil, nil) }
        defer { try? file.close() }
        let cap = 512_000
        guard let size = try? file.seekToEnd(),
              (try? file.seek(toOffset: size > UInt64(cap) ? size - UInt64(cap) : 0)) != nil,
              let bytes = try? file.read(upToCount: cap) else { return (nil, nil) }
        var response: String?
        var exactResponse: String?
        for line in bytes.split(separator: 0x0A).reversed() {
            guard let entry = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let type = entry["type"] as? String, type == "user" || type == "assistant",
                  entry["isSidechain"] as? Bool != true, entry["isMeta"] as? Bool != true,
                  let message = entry["message"] as? [String: Any] else { continue }
            let blocks = message["content"] as? [[String: Any]] ?? []
            let text = message["content"] as? String ?? blocks.compactMap {
                $0["type"] as? String == "text" ? $0["text"] as? String : nil
            }.joined(separator: "\n")
            guard let text = clean(text, limit: type == "user" ? 1250 : (working ? 500 : 2500)),
                  !text.hasPrefix("<local-command"), !text.hasPrefix("<system-reminder"),
                  !text.hasPrefix("<command-name>"), !text.hasPrefix("[Request interrupted") else { continue }
            if type == "user" { return (text, exactResponse ?? response) }
            if response == nil { response = text }
            if !working && exactResponse == nil && entry["uuid"] as? String == assistantID { exactResponse = text }
        }
        return (nil, exactResponse ?? response)
    }

    private var cursorDatabase: URL {
        home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    private func cursor(_ session: Session, includeTranscript: Bool) -> SessionEvidence {
        guard let id = Self.id(session, prefix: "cursor:"), case let .url(raw) = session.route,
              let url = URL(string: raw) else { return SessionEvidence() }
        if url.path == "/background-agent" { return cursorCloud(session, id: id, includeTranscript: includeTranscript) }
        guard url.path == "/agent" else { return SessionEvidence() }
        let key = "composerData:" + id
        let action = Self.query(cursorDatabase, """
            SELECT substr(json_extract(todo.value, '$.content'), 1, 500)
            FROM cursorDiskKV AS body, json_each(body.value, '$.todos') AS todo
            WHERE body.key = ?1 AND length(body.value) < 8000000 AND json_valid(body.value)
              AND todo.type = 'object' AND json_extract(todo.value, '$.status') = 'pending'
            ORDER BY CAST(todo.key AS INTEGER) LIMIT 1
            """, [key], columns: 1)[0]
        var evidence = SessionEvidence(pendingAction: Self.action(action))
        guard includeTranscript else { return evidence }
        let pair = Self.query(cursorDatabase, """
            WITH messages AS (
                SELECT CAST(header.key AS INTEGER) AS position, json_extract(header.value, '$.type') AS role,
                       json_extract(header.value, '$.bubbleId') AS id
                FROM cursorDiskKV AS body, json_each(body.value, '$.fullConversationHeadersOnly') AS header
                WHERE body.key = ?1 AND length(body.value) < 8000000 AND json_valid(body.value)
            ), bodies AS (
                SELECT position, role, substr(json_extract(bubble.value, '$.text'), 1, 3000) AS text
                FROM messages JOIN cursorDiskKV AS bubble ON bubble.key = ?2 || messages.id
                WHERE messages.role IN (1, 2) AND length(bubble.value) < 1000000 AND json_valid(bubble.value)
            )
            SELECT (SELECT text FROM bodies WHERE role = 1 AND length(trim(text)) > 0
                    ORDER BY position DESC LIMIT 1),
                   (SELECT text FROM bodies WHERE role = 2 AND length(trim(text)) > 0
                    AND position > COALESCE((SELECT MAX(position) FROM messages WHERE role = 1), -1)
                    ORDER BY position DESC LIMIT 1)
            """, [key, "bubbleId:" + id + ":"], columns: 2)
        evidence.latestRequest = Self.clean(pair[0], limit: 1250)
        if session.status == .working, let progress = Self.clean(pair[1], limit: 500) {
            evidence.activityContext = "Cursor’s latest progress message: " + progress
        } else {
            evidence.latestOutcome = Self.clean(pair[1], limit: 2500)
        }
        return evidence
    }

    private func cursorCloud(_ session: Session, id: String, includeTranscript: Bool) -> SessionEvidence {
        let account = Self.query(cursorDatabase, "SELECT value FROM ItemTable WHERE key = 'glass.lastSignedInAuthId'",
                                 [], columns: 1)[0]
        let metadata: [String?]
        if let account, let suffix = account.addingPercentEncoding(withAllowedCharacters: DesktopProvider.componentCharacters) {
            metadata = Self.query(cursorDatabase, """
                SELECT json_extract(agent.value, '$.workflowStatus'), json_extract(agent.value, '$.status'),
                       json_extract(agent.value, '$.prStatus'), json_extract(agent.value, '$.filesChanged')
                FROM ItemTable AS roster, json_each(roster.value) AS agent
                WHERE roster.key = ?1 AND length(roster.value) < 4000000 AND json_valid(roster.value)
                  AND agent.type = 'object' AND json_extract(agent.value, '$.bcId') = ?2 LIMIT 1
                """, ["cloudAgentRepository.agents." + suffix, id], columns: 4)
        } else {
            metadata = [nil, nil, nil, nil]
        }

        var evidence = SessionEvidence()
        var context: [String] = []
        // Cursor's installed CloudAgentWorkflowStatus and BackgroundComposerStatus wire enums.
        if metadata[0] == "3" || metadata[1] == "3" { context.append("Cursor reports the cloud run failed.") }
        else if metadata[0] == "6" { context.append("Cursor reports the cloud run has not started.") }
        else if metadata[0] == "7" { context.append("Cursor reports the cloud run is waiting for background work.") }
        else if metadata[0] == "2", metadata[1] == "2" { context.append("Cursor reports the cloud run finished.") }
        if let count = metadata[3].flatMap(Int.init), count > 0 {
            context.append("Cursor records changes to \(count) \(count == 1 ? "file" : "files").")
        }
        switch metadata[2] {
        case "1": evidence.pendingAction = "Review the open pull request."
        case "2": context.append("A draft pull request exists.")
        case "3": context.append("The pull request was merged.")
        case "4": context.append("The pull request was closed.")
        default: break
        }
        if includeTranscript {
            let database = cursorDatabase.deletingLastPathComponent().appendingPathComponent("conversation-search.db")
            // Cursor's transcript index serializes turns newest first, with role headings on their own lines.
            let row = Self.query(database, """
                SELECT conversation.updated_at, substr(messages.body, 1, 28000)
                FROM conversations AS conversation
                JOIN conversation_fts AS messages ON messages.rowid = conversation.fts_rowid
                WHERE conversation.source = 'cloud-cache' AND conversation.id = ?1
                  AND COALESCE(conversation.is_archived, 0) = 0
                ORDER BY conversation.updated_at DESC LIMIT 1
                """, [id], columns: 2)
            if let cachedAt = row[0].flatMap(Int64.init), let body = row[1] {
                let pair = Self.cursorCloudMessages(body)
                let expected = session.activityID.flatMap(Int64.init)
                    ?? Int64(session.updatedAt.timeIntervalSince1970 * 1_000)
                // Cursor's copy of a cloud chat trails the cloud, often by more than a few seconds. During a
                // run the newest request in it is still the one being worked on in nearly every case, so it
                // stands as the request; right after a follow-up it can be one message behind until the copy
                // catches up. Once the run has ended, only a copy that has caught up can say what came of it,
                // and until then Cursor's own report of the run is all there is to go on.
                let caughtUp = cachedAt >= expected - 15_000
                if caughtUp || session.status == .working { evidence.latestRequest = pair.request }
                if session.status == .working {
                    if let response = pair.response {
                        context.append("Cursor’s latest progress message: " + String(response.prefix(500)))
                    }
                } else if caughtUp {
                    evidence.latestOutcome = pair.response
                }
            }
        }
        evidence.activityContext = context.isEmpty ? nil : context.joined(separator: " ")
        return evidence
    }

    static func cursorCloudMessages(_ body: String) -> (request: String?, response: String?) {
        let lines = body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var role: String?
        var pieces: [Substring] = []
        var response: String?
        var request: String?
        func finish() {
            let text = Self.clean(pieces.joined(separator: "\n"), limit: role == "user:" ? 1250 : 2500)
            if role == "user:" { request = text }
            else if role == "assistant:", response == nil { response = text }
        }
        var previousWasBlank = true
        for line in lines {
            let label = line.lowercased()
            if previousWasBlank && (label == "user:" || label == "assistant:") {
                finish()
                if request != nil { return (request, response) }
                role = label
                pieces = []
            } else if role != nil {
                pieces.append(line)
            }
            previousWasBlank = line.isEmpty
        }
        finish()
        return (request, response)
    }

    private struct GrokEnvelope<Value: Decodable>: Decodable { let value: Value }

    private struct GrokRoster: Decodable {
        struct Row: Decodable {
            let id: String
            let lastMessageId: String?
            let newestEntryId: String?
            let awaitingUserResponse: Pending?
        }

        struct Pending: Decodable {
            struct Copy: Decodable {
                struct Parameters: Decodable {
                    let summary: String?
                    let summaryCopy: String?
                }
                let params: Parameters?
            }

            let reason: String?
            let reasonCopy: Copy?
            enum CodingKeys: String, CodingKey { case reason, reasonCopy }

            init(from decoder: Decoder) throws {
                let fields = try decoder.container(keyedBy: CodingKeys.self)
                reason = try? fields.decode(String.self, forKey: .reason)
                reasonCopy = try? fields.decode(Copy.self, forKey: .reasonCopy)
            }
        }

        let rows: [Row]
    }

    private struct GrokTranscript: Decodable {
        struct Entry: Decodable {
            struct OutgoingMessage: Decodable {
                let type: String?
                let content: String?
            }

            let kind: String
            let id: String?
            let role: String?
            let content: String?
            let message: OutgoingMessage?
            let requestId: String?
            let timestampMs: Int64?
            let isStreaming: Bool?
            let sentByAgent: Bool

            enum CodingKeys: String, CodingKey {
                case kind, id, role, content, message, requestId, timestampMs, isStreaming, fromAgent
            }

            init(from decoder: Decoder) throws {
                let fields = try decoder.container(keyedBy: CodingKeys.self)
                kind = (try? fields.decode(String.self, forKey: .kind)) ?? ""
                id = try? fields.decode(String.self, forKey: .id)
                role = try? fields.decode(String.self, forKey: .role)
                content = try? fields.decode(String.self, forKey: .content)
                message = try? fields.decode(OutgoingMessage.self, forKey: .message)
                requestId = try? fields.decode(String.self, forKey: .requestId)
                timestampMs = try? fields.decode(Int64.self, forKey: .timestampMs)
                isStreaming = try? fields.decode(Bool.self, forKey: .isStreaming)
                sentByAgent = fields.contains(.fromAgent) && (try? fields.decodeNil(forKey: .fromAgent)) != true
            }

            var reply: String? {
                guard isStreaming != true else { return nil }
                if kind == "send-message", message?.type == "text" { return message?.content }
                if kind == "message", role == "assistant" { return content }
                return nil
            }

            var request: String? {
                kind == "message" && role == "user" && !sentByAgent ? content : nil
            }
        }

        let entries: [Entry]
    }

    private func grok(_ session: Session, includeTranscript: Bool) -> SessionEvidence {
        guard let id = Self.id(session, prefix: "grok:") else { return SessionEvidence() }
        let root = home.appendingPathComponent("Library/Application Support/Grok Bot/sand-client-persistence")
        let slot = root.appendingPathComponent(DesktopProvider.grokBlobName("sand.client.slice.client-meta.account-slot"))
        guard let account = Self.decode(GrokEnvelope<String>.self, at: slot, limit: 4096)?.value,
              !account.isEmpty,
              let encoded = account.addingPercentEncoding(withAllowedCharacters: DesktopProvider.componentCharacters)
        else { return SessionEvidence() }
        let prefix = "sand.client.slice.account." + encoded + "."
        let rosterFile = root.appendingPathComponent(DesktopProvider.grokBlobName(prefix + "roster.last-roster"))
        let row = Self.decode(GrokEnvelope<GrokRoster>.self, at: rosterFile, limit: 2_000_000)?
            .value.rows.first { $0.id == id }
        let pending = row?.awaitingUserResponse
        var evidence = SessionEvidence(pendingAction: Self.action(
            pending?.reasonCopy?.params?.summary ?? pending?.reasonCopy?.params?.summaryCopy ?? pending?.reason
        ))
        guard includeTranscript else { return evidence }
        let path = root.appendingPathComponent(DesktopProvider.grokBlobName(prefix + "transcript.replicas." + id))
        guard let entries = Self.decode(GrokEnvelope<GrokTranscript>.self, at: path, limit: 2_000_000)?.value.entries
        else { return evidence }
        let latestIDs = Set([row?.lastMessageId, row?.newestEntryId].compactMap { $0 })
        let recent = entries.suffix(80)
        if let latest = recent.reversed().first(where: { $0.id.map { latestIDs.contains($0) } == true }),
           let reply = Self.clean(latest.reply, limit: 2500) {
            evidence.latestOutcome = reply
            if let requestID = latest.requestId {
                evidence.latestRequest = recent.reversed()
                    .first { $0.requestId == requestID && $0.request != nil }
                    .flatMap { Self.clean($0.request, limit: 1250) }
            }
            return evidence
        }
        let activityTime = Int64(session.updatedAt.timeIntervalSince1970 * 1_000)
        for entry in recent.reversed() where (entry.timestampMs ?? 0) >= activityTime - 20_000 {
            if let request = Self.clean(entry.request, limit: 1250) {
                evidence.latestRequest = request
                break
            }
            if let reply = Self.clean(entry.reply, limit: 2500) {
                evidence.latestOutcome = reply
                break
            }
        }
        return evidence
    }

    private static func id(_ session: Session, prefix: String) -> String? {
        guard session.id.hasPrefix(prefix) else { return nil }
        let suffix = String(session.id.dropFirst(prefix.count))
        return validKey(suffix) ? suffix : nil
    }

    private static func validKey(_ key: String) -> Bool {
        key.range(of: #"^[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil
    }

    private static func directories(_ url: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        return urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, at url: URL, limit: Int) -> Value? {
        guard let metadata = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              metadata.isRegularFile == true, let size = metadata.fileSize, size <= limit,
              let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let bytes = try? file.read(upToCount: limit + 1), bytes.count <= limit else { return nil }
        return try? JSONDecoder().decode(type, from: bytes)
    }

    private static func query(_ url: URL, _ sql: String, _ arguments: [String], columns: Int) -> [String?] {
        let empty = Array<String?>(repeating: nil, count: columns)
        guard let database = ReadOnlySQLite.open(url) else { return empty }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 35)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return empty }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, argument) in arguments.enumerated() {
            guard sqlite3_bind_text(statement, Int32(offset + 1), argument, -1, transient) == SQLITE_OK else {
                return empty
            }
        }
        guard sqlite3_step(statement) == SQLITE_ROW else { return empty }
        return (0..<columns).map { column in
            sqlite3_column_text(statement, Int32(column)).map { String(cString: $0) }
        }
    }

    private static func action(_ text: String?) -> String? {
        guard let value = clean(text, limit: 360) else { return nil }
        let generic = ["yes", "no", "true", "false", "none", "nothing", "n/a", "no action", "no action needed",
                       "no action required", "completed", "blocked"]
        let normalized = value.lowercased().trimmingCharacters(in: .punctuationCharacters)
        return generic.contains(normalized) ? nil : value
    }

    private static func clean(_ text: String?, limit: Int) -> String? {
        guard let text else { return nil }
        let sanitized = String(text.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t"
        })
        let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(limit))
    }
}
