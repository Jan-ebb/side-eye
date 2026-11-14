import AppKit
import SQLite3

@MainActor
enum SelfChecks {
    static func run() {
        let store = SessionStore(defaults: nil)
        var alerts: [Session] = []
        store.onAttention = { alerts += $0 }
        let now = Date()
        let current = sample("codex", .codex, "Sidebar keyboard flow", .working, now)
        let other = sample("cursor", .cursor, "Export bug", .ready, now)
        let blocked = sample("claude", .claude, "Repository cleanup", .needsInput, now)
        store.ingest([current, other, blocked])
        precondition(alerts.isEmpty, "Startup should not show nudges for existing items")
        precondition(store.attentionCount == 2 && store.nextAttention()?.id == blocked.id)

        let ready = sample("codex", .codex, "Sidebar keyboard flow", .ready, now, activityID: "turn-1")
        store.ingest([ready, other, blocked])
        precondition(alerts.map(\.id) == [current.id])
        precondition(store.rows.first { $0.id == current.id }?.statusLabel == "To review")
        store.acknowledge(ready)
        store.ingest([ready, other, blocked])
        precondition(alerts.count == 1 && store.attentionCount == 2)
        precondition(store.rows.first { $0.id == current.id }?.statusLabel == "Read")
        store.markUnread(ready)
        precondition(store.rows.first { $0.id == current.id }?.isManuallyUnread == true)
        precondition(store.rows.first { $0.id == current.id }?.statusLabel == "To review")
        store.markRead(ready)
        precondition(store.rows.first { $0.id == current.id }?.statusLabel == "Read" && alerts.count == 1)

        let next = sample("codex", .codex, "Sidebar keyboard flow", .ready, now, activityID: "turn-2")
        store.ingest([next, other, blocked])
        precondition(alerts.count == 2 && store.attentionCount == 3)
        store.hide(next)
        store.ingest([next, other, blocked])
        precondition(store.rows.count == 2 && store.hiddenCount == 1)
        precondition(store.undoHide() && store.rows.count == 3)

        store.setQuery("cursor export")
        precondition(store.shownRows.map(\.id) == [other.id] && store.selectedID == other.id)
        precondition(store.session(in: 1)?.id == other.id && store.session(in: 2) == nil)
        store.setQuery("none")
        precondition(store.shownRows.isEmpty && store.selectedID == nil)
        store.setQuery("")
        precondition(store.shownRows.count == 3)

        let extra = sample("extra", .grok, "Extra session", .idle, now)
        store.ingest([next, blocked, extra])
        precondition(store.rows.contains { $0.id == other.id }, "A single missed scan should retain the row")
        var lateSummary = next
        lateSummary.stateSummary = "The keyboard flow passed its checks."
        let alertCount = alerts.count
        store.applySummaries(from: [lateSummary])
        precondition(store.rows.first { $0.id == next.id }?.session.stateSummary == lateSummary.stateSummary)
        precondition(store.rows.contains { $0.id == other.id } && alerts.count == alertCount,
                     "A summary update should neither consume a missing scan nor replay a nudge")
        var priorSummary = ready
        priorSummary.stateSummary = "An older turn completed."
        store.applySummaries(from: [priorSummary])
        precondition(store.rows.first { $0.id == next.id }?.session.stateSummary == lateSummary.stateSummary)
        store.ingest([next, blocked, extra])
        precondition(!store.rows.contains { $0.id == other.id })

        let beta = sample("beta", .grok, "Filtered beta", .idle, now)
        let gamma = sample("gamma", .grok, "Filtered gamma", .idle, now)
        let delta = sample("delta", .grok, "Filtered delta", .idle, now)
        store.ingest([next, blocked, extra, beta, gamma, delta])
        store.setQuery("filtered")
        let first = store.shownRows[0].session
        let second = store.shownRows[1].id
        store.hide(first)
        precondition(store.selectedID == second, "Remove should select the next filtered row")
        precondition(store.session(in: 1)?.id == second, "Filtered results should renumber after archive")

        var read = sample("read", .codex, "Already reviewed", .ready, now, activityID: "turn")
        read.reviewedBySource = true
        let previousAlerts = alerts.count
        store.ingest([read])
        precondition(store.rows.first(where: { $0.id == read.id })?.needsReview == false)
        precondition(alerts.count == previousAlerts)

        let many = (1...13).map {
            sample("many-\($0)", .codex, "Session \($0)", .idle, now.addingTimeInterval(-Double($0)))
        }
        let crowded = SessionStore(defaults: nil)
        crowded.ingest(many)
        precondition(crowded.rows.count == 13)
        precondition(crowded.quietCollapsed && crowded.shownRows.isEmpty
                     && crowded.sidebarItems == [.allClear, .header(.quiet, count: 13, collapsed: true)],
                     "Quiet should start folded and say that nothing needs you")
        crowded.setQuietCollapsed(false)
        precondition(Shortcut.numbers.compactMap { crowded.session(in: $0)?.id } == many.prefix(9).map(\.id))
        precondition(crowded.session(in: 10)?.id == "many-10")
        crowded.numberEntry = ""
        crowded.appendJumpDigit("1")
        crowded.appendJumpDigit("2")
        precondition(crowded.enteredSession?.id == "many-12")
        precondition(crowded.rows.first?.statusLabel == "Idle")
        crowded.setQuery("session 13")
        precondition(crowded.shownRows.map(\.id) == ["many-13"])
        precondition(crowded.session(in: 1)?.id == "many-13" && crowded.session(in: 2) == nil)
        precondition(crowded.numberEntry == "" && crowded.selectedID == "many-13")

        checkAttentionFilters(now: now)
        checkAttentionMarkers(now: now)
        checkLater(now: now)
        checkArchive(now: now)
        checkArchiveReturns(now: now)
        checkGrouping(now: now)
        checkPalette(now: now)

        let ordered = SessionStore(defaults: nil)
        let older = sample("older", .codex, "Older completion", .ready, now,
                           completedAt: now.addingTimeInterval(-3_600))
        let newer = sample("newer", .cursor, "Newer completion", .ready, now.addingTimeInterval(-600),
                           completedAt: now.addingTimeInterval(-600))
        ordered.ingest([older, newer, blocked])
        precondition(ordered.rows.map(\.id) == ["newer", "older", blocked.id],
                     "Completion order should win over last activity")
        precondition(ordered.shownRows.map(\.id) == [blocked.id, newer.id, older.id],
                     "Only the next action should move ahead of completion order")
        precondition((1...3).compactMap { ordered.session(in: $0)?.id } == ordered.shownRows.map(\.id),
                     "Number shortcuts should follow the displayed rows from the top")
        precondition(ordered.nextAttention()?.id == blocked.id, "Input requests should stay first in the attention queue")

        let finished = sample("older", .codex, "Finished again", .ready, now, activityID: "turn-2", completedAt: now)
        ordered.ingest([finished, newer, blocked])
        precondition(ordered.session(in: 2)?.id == finished.id && ordered.session(in: 3)?.id == newer.id,
                     "A new completion should change its shortcut to match its new row")
        ordered.hide(finished)
        precondition(ordered.session(in: 2)?.id == newer.id)
        precondition(ordered.undoHide() && ordered.session(in: 2)?.id == finished.id)

        let running = sample("older", .codex, "Running another turn", .working, now.addingTimeInterval(1))
        ordered.ingest([running, newer, blocked])
        precondition(ordered.rows.first?.session.completedAt == now,
                     "Starting another turn should preserve the last known completion time")

        let grokScope = SessionStore(defaults: nil)
        let main = sample("grok:main", .grok, "Main", .idle, now)
        let child = sample("grok:child", .grok, "Child", .idle, now)
        grokScope.ingest([main, child, newer])
        grokScope.toggleGrokMain(id: main.id)
        grokScope.setGrokMainOnly(true)
        precondition(Set(grokScope.rows.map(\.id)) == [main.id, newer.id])
        precondition(Set(grokScope.availableGrokSessions.map(\.id)) == [main.id, child.id])
        grokScope.onAttention = { _ in preconditionFailure("Filtered Grok chats should stay out of the review queue") }
        grokScope.ingest([main, sample(child.id, .grok, child.title, .ready, now), newer])
        precondition(grokScope.nextAttention()?.id == newer.id && grokScope.count(for: .toReview) == 1)
        grokScope.setGrokMainOnly(false)
        precondition(grokScope.rows.contains { $0.id == child.id } && grokScope.count(for: .toReview) == 2)

        let age = SessionStore(defaults: nil)
        let quiet = sample("quiet", .grok, "Quiet session", .idle, now.addingTimeInterval(-8 * 3600 + 2))
        let oldWorking = sample("working", .codex, "Still working", .working, quiet.updatedAt)
        let oldInput = sample("input", .claude, "Still waiting for input", .needsInput, quiet.updatedAt)
        age.ingest([quiet, oldWorking, oldInput], now: now)
        precondition(age.rows.first { $0.id == quiet.id }?.statusLabel == "Idle")
        age.ingest([quiet, oldWorking, oldInput], now: now.addingTimeInterval(3))
        precondition(age.rows.first { $0.id == quiet.id }?.statusLabel == "Inactive")
        precondition(age.rows.first { $0.id == oldWorking.id }?.statusLabel == "Working")
        precondition(age.rows.first { $0.id == oldInput.id }?.statusLabel == "Needs input")
        checkRailPlacement()
        checkCodexAutomationVisibility(now: now)
        print("Session checks passed (attention, Later, Archive, search, layouts, completion order, grouping, shortcuts, status age, Grok scope and summaries).")
        print("Rail placement checks passed.")
        print("Codex automation visibility checks passed.")
    }

    private static func checkCodexAutomationVisibility(now: Date) {
        let files = FileManager.default
        let home = files.temporaryDirectory.appendingPathComponent("relay-codex-fixture-" + UUID().uuidString, isDirectory: true)
        let desktop = home.appendingPathComponent("sqlite", isDirectory: true)
        try! files.createDirectory(at: desktop, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: home) }

        let regular = "00000000-0000-4000-8000-000000000001"
        let heartbeat = "00000000-0000-4000-8000-000000000002"
        let followUp = "00000000-0000-4000-8000-000000000003"
        let standalone = "00000000-0000-4000-8000-000000000004"
        let fallback = "00000000-0000-4000-8000-000000000005"
        let unrelated = "00000000-0000-4000-8000-000000000006"
        let seconds = Int64(now.timeIntervalSince1970)
        let recency = seconds * 1000
        createFixtureDatabase(at: home.appendingPathComponent("state_5.sqlite"), sql: """
            CREATE TABLE threads (
                id TEXT PRIMARY KEY, source TEXT, title TEXT, cwd TEXT, updated_at INTEGER,
                archived INTEGER, thread_source TEXT, recency_at_ms INTEGER,
                attached_thread_parent_id TEXT, preview TEXT
            );
            INSERT INTO threads VALUES
                ('\(regular)', 'vscode', 'Regular chat', '/tmp', \(seconds), 0, 'user', \(recency), NULL, 'Regular'),
                ('\(heartbeat)', 'vscode', 'Heartbeat', '/tmp', \(seconds), 0, 'user', \(recency), NULL, 'Heartbeat'),
                ('\(followUp)', 'vscode', 'Manual follow-up', '/tmp', \(seconds), 0, 'user', \(recency), NULL, 'Follow-up'),
                ('\(standalone)', 'exec', 'Standalone run', '/tmp', \(seconds), 0, 'automation', \(recency), NULL, 'Run'),
                ('\(fallback)', 'vscode', 'Projected heartbeat', '/tmp', \(seconds), 0, 'user', \(recency), NULL, 'Projected'),
                ('\(unrelated)', 'exec', 'Unrelated CLI execution', '/tmp', \(seconds), 0, 'user', \(recency), NULL, 'CLI');
            """)
        let envelope = "<heartbeat>\n  <automation_id>fixture</automation_id>\n  <current_time_iso>2026-01-01T00:00:00.000Z</current_time_iso>\n  <instructions>\nCheck the fixture.\n  </instructions>\n</heartbeat>\n"
        let envelopeItem = "json_object('content', json_array(json_object('type', 'text', 'text', '\(envelope)')))"
        let manualItem = "json_object('content', json_array(json_object('type', 'text', 'text', 'Continue the chat.')))"
        createFixtureDatabase(at: home.appendingPathComponent("thread_history_1.sqlite"), sql: """
            CREATE TABLE thread_turns (
                thread_id TEXT, turn_id TEXT, rollout_ordinal INTEGER, status TEXT, started_at INTEGER,
                completed_at INTEGER, first_user_item_id TEXT, PRIMARY KEY (thread_id, turn_id)
            );
            CREATE TABLE thread_items (
                thread_id TEXT, turn_id TEXT, item_id TEXT, item_type TEXT, item_json TEXT,
                PRIMARY KEY (thread_id, turn_id, item_id)
            );
            INSERT INTO thread_turns VALUES
                ('\(regular)', 'manual', 1, 'completed', \(seconds - 2), \(seconds), 'first'),
                ('\(heartbeat)', 'heartbeat', 1, 'completed', \(seconds - 2), \(seconds), 'first'),
                ('\(followUp)', 'heartbeat', 1, 'completed', \(seconds - 30), \(seconds - 20), 'first'),
                ('\(followUp)', 'manual', 2, 'completed', \(seconds - 2), \(seconds), 'first'),
                ('\(standalone)', 'run', 1, 'completed', \(seconds - 2), \(seconds), 'first'),
                ('\(fallback)', 'heartbeat', 1, 'completed', \(seconds - 2), \(seconds), 'not-projected-yet');
            INSERT INTO thread_items VALUES
                ('\(regular)', 'manual', 'first', 'userMessage', \(manualItem)),
                ('\(heartbeat)', 'heartbeat', 'first', 'userMessage', \(envelopeItem)),
                ('\(followUp)', 'heartbeat', 'first', 'userMessage', \(envelopeItem)),
                ('\(followUp)', 'manual', 'first', 'userMessage', \(manualItem));
            """)
        createFixtureDatabase(at: desktop.appendingPathComponent("codex.db"), sql: """
            CREATE TABLE automation_runs (thread_id TEXT PRIMARY KEY);
            CREATE TABLE automations (id TEXT PRIMARY KEY, target_thread_id TEXT, kind TEXT, last_run_at INTEGER);
            INSERT INTO automation_runs VALUES ('\(standalone)');
            INSERT INTO automations VALUES
                ('fixture', '\(followUp)', 'heartbeat', \((seconds - 2) * 1000)),
                ('fallback', '\(fallback)', 'heartbeat', \((seconds - 2) * 1000));
            """)

        let provider = CodexProvider(home: home)
        let manualIDs = Set([regular, followUp].map { "codex:" + $0 })
        let automationIDs = Set([heartbeat, standalone, fallback].map { "codex:" + $0 })
        let hidden = provider.scan()
        let included = provider.scan(includeAutomationRuns: true)
        precondition(Set(hidden.map(\.id)) == manualIDs && hidden.allSatisfy { $0.isAutomationRun != true },
                     "The default scan must preserve regular and manual follow-up chats")
        precondition(Set(included.filter { $0.isAutomationRun == true }.map(\.id)) == automationIDs,
                     "Opt-in must identify heartbeat envelopes, standalone records and missing-item fallback")
        precondition(Set(included.map(\.id)) == manualIDs.union(automationIDs))
        precondition(Set(provider.scan().map(\.id)) == manualIDs, "Disabling automation runs must apply on the next scan")

        let store = SessionStore(defaults: nil)
        store.ingest(hidden, now: now)
        var alerts: [String] = []
        store.onAttention = { alerts += $0.map(\.id) }
        store.ingest(included, now: now)
        precondition(!store.showsAutomationRuns && Set(store.rows.map(\.id)) == manualIDs)
        precondition(store.attentionCount == 2 && store.count(for: .toReview) == 2 && store.session(in: 3) == nil)
        precondition(store.nextAttention()?.isAutomationRun != true && alerts.isEmpty,
                     "Hidden runs must stay out of the attention queue and never nudge")
        store.setShowsAutomationRuns(true)
        precondition(store.attentionCount == 5 && Set(store.rows.map(\.id)) == manualIDs.union(automationIDs) && alerts.isEmpty)
        store.selectedID = "codex:" + heartbeat
        store.setShowsAutomationRuns(false)
        precondition(store.attentionCount == 2 && manualIDs.contains(store.selectedID ?? "") && alerts.isEmpty,
                     "Disabling automation runs must remove visible rows and reconcile selection immediately")
    }

    private static func createFixtureDatabase(at url: URL, sql: String) {
        var database: OpaquePointer?
        let result = sqlite3_open(url.path, &database)
        defer { sqlite3_close(database) }
        precondition(result == SQLITE_OK && database != nil, "Could not create SQLite fixture")
        let executed = sqlite3_exec(database, sql, nil, nil, nil)
        precondition(executed == SQLITE_OK, String(cString: sqlite3_errmsg(database)))
    }

    private static func checkRailPlacement() {
        let visible = CGRect(x: 100, y: 30, width: 1_440, height: 1_000)
        let size = CGSize(width: 18, height: 60)
        let inset = RailPlacement.screenInset
        let defaultRail = RailPlacement.railFrame(in: visible, size: size, fraction: nil)
        precondition(defaultRail.maxX == visible.maxX - 3 && defaultRail.maxY == visible.maxY - 190)
        let shorter = CGRect(x: 100, y: 30, width: 1_440, height: 420)
        precondition(RailPlacement.railFrame(in: shorter, size: size, fraction: nil).maxY == shorter.maxY - 84)

        let bottomRail = RailPlacement.railFrame(in: visible, size: size, fraction: 0)
        let topRail = RailPlacement.railFrame(in: visible, size: size, fraction: 1)
        precondition(bottomRail.minY == visible.minY + inset && topRail.maxY == visible.maxY - inset)
        precondition(RailPlacement.fraction(forCenterY: visible.minY - 20, in: visible, size: size) == 0)
        precondition(RailPlacement.fraction(forCenterY: visible.maxY + 20, in: visible, size: size) == 1)
        precondition(RailPlacement.railFrame(in: visible, size: size, fraction: -.infinity) == defaultRail)
        precondition(RailPlacement.railFrame(in: visible, size: size, fraction: .nan) == defaultRail)
        precondition(RailPlacement.railFrame(in: visible, size: size, fraction: -0.2) == bottomRail)
        precondition(RailPlacement.railFrame(in: visible, size: size, fraction: 1.2) == topRail)

        let secondary = CGRect(x: -1_512, y: -530, width: 1_512, height: 840)
        let secondaryRail = RailPlacement.railFrame(in: secondary, size: size, fraction: 0.32)
        let saved = RailPlacement.fraction(forCenterY: secondaryRail.midY, in: secondary, size: size)
        precondition(abs(saved - 0.32) < 0.0001 && secondaryRail.maxX == secondary.maxX - 3)
        let resized = CGRect(x: -1_920, y: -720, width: 1_920, height: 1_080)
        let resizedRail = RailPlacement.railFrame(in: resized, size: size, fraction: saved)
        precondition(abs(RailPlacement.fraction(forCenterY: resizedRail.midY, in: resized, size: size) - saved) < 0.0001)
        precondition(resizedRail.midY != secondaryRail.midY)

        let tiny = CGRect(x: 0, y: -70, width: 300, height: 70)
        let tinyRail = RailPlacement.railFrame(in: tiny, size: size, fraction: 0)
        precondition(tinyRail.midY == tiny.midY && tinyRail.minY >= tiny.minY)
        precondition(RailPlacement.fraction(forCenterY: tinyRail.midY, in: tiny, size: size) == 0.5)

        let height: CGFloat = 430
        precondition(RailPlacement.panelTop(for: height, near: defaultRail.maxY, in: visible) == defaultRail.maxY)
        let raisedTop = RailPlacement.panelTop(for: height, near: bottomRail.maxY, in: visible)
        precondition(raisedTop - height == visible.minY + inset, "A panel near the lower rail must fit on-screen")
        precondition(RailPlacement.panelTop(for: 46, near: bottomRail.maxY, in: visible) == bottomRail.maxY)
        precondition(RailPlacement.panelTop(for: height, near: visible.maxY + 20, in: visible) == visible.maxY - inset)
        precondition(RailPlacement.panelTop(for: visible.height, near: bottomRail.maxY, in: visible) == visible.maxY)
    }

    private static func checkAttentionFilters(now: Date) {
        let store = SessionStore(defaults: nil)
        let newest = sample("newest", .codex, "Export retry", .ready, now.addingTimeInterval(-120),
                            completedAt: now.addingTimeInterval(-120), stateSummary: "Rerun the staging checks.")
        let older = sample("older", .cursor, "Export layout", .ready, now.addingTimeInterval(-180),
                           completedAt: now.addingTimeInterval(-600), stateSummary: "Check the staging layout.")
        let blocked = sample("blocked", .claude, "Export approval", .needsInput, now)
        let working = sample("working", .grok, "Export tests", .working, now, stateSummary: "Running staging tests.")
        let quiet = sample("quiet", .grok, "Export notes", .idle, now)
        var read = sample("read", .codex, "Reviewed export", .ready, now, completedAt: now)
        read.reviewedBySource = true
        let fixtures = [newest, older, blocked, working, quiet, read]
        store.ingest(fixtures, now: now)
        store.markUnread(working)
        store.markUnread(quiet)
        precondition(store.filter == .all && store.count(for: .all) == fixtures.count)
        precondition(store.count(for: .needsInput) == 1 && store.count(for: .toReview) == 2)
        precondition(!store.showsAllSummaries, "A new sidebar should default to Compact")

        var changes = 0
        store.onRowsChanged = { changes += 1 }
        store.setFilter(.toReview)
        precondition(changes == 1 && store.selectedID == newest.id)
        precondition(store.shownRows.map(\.id) == [newest.id, older.id], "Review filter must preserve completion order")
        precondition(store.session(in: 2)?.id == older.id && store.session(in: 3) == nil)
        precondition(store.nextAttention()?.id == blocked.id, "The visible filter must leave the global attention queue intact")
        store.setFilter(.toReview)
        precondition(changes == 1)

        store.setQuery("staging")
        store.numberEntry = ""
        store.appendJumpDigit("2")
        for expanded in [true, false] {
            store.setShowsAllSummaries(expanded)
            precondition(store.showsAllSummaries == expanded)
            precondition(store.filter == .toReview && store.query == "staging")
            precondition(store.shownRows.map(\.id) == [newest.id, older.id],
                         "Both layouts must search summaries within the same filtered rows")
            precondition(store.session(in: 1)?.id == newest.id && store.session(in: 2)?.id == older.id)
            precondition(store.numberEntry == "2" && store.enteredSession?.id == older.id && store.selectedID == older.id,
                         "Switching summary layouts must preserve the entered row")
        }
        store.numberEntry = nil
        store.setQuery("cursor export")
        precondition(store.shownRows.map(\.id) == [older.id] && store.selectedID == older.id)
        precondition(store.session(in: 1)?.id == older.id && store.count(for: .toReview) == 2)
        store.setFilter(.needsInput)
        precondition(store.shownRows.isEmpty && store.selectedID == nil && store.count(for: .needsInput) == 1)
        store.setQuery("")
        precondition(store.shownRows.map(\.id) == [blocked.id] && store.selectedID == blocked.id)
        store.acknowledge(blocked)
        precondition(store.shownRows.map(\.id) == [blocked.id] && store.count(for: .needsInput) == 1,
                     "Opening a chat must leave its pending input in the filter")
        precondition(!store.shownRows[0].needsReview)

        store.setFilter(.toReview)
        store.markRead(newest)
        precondition(store.shownRows.map(\.id) == [older.id] && store.count(for: .toReview) == 1)
        store.markUnread(newest)
        precondition(store.shownRows.map(\.id) == [newest.id, older.id])
        store.hide(older)
        precondition(store.count(for: .toReview) == 1)
        precondition(store.undoHide() && store.session(in: 2)?.id == older.id)
        store.acknowledge(older)
        precondition(store.shownRows.map(\.id) == [newest.id])

        let secondRequest = sample("blocked-2", .claude, "More export approval", .needsInput, now)
        var alerts: [String] = []
        store.onAttention = { alerts += $0.map(\.id) }
        store.ingest(fixtures + [secondRequest], now: now)
        precondition(alerts == [secondRequest.id] && store.shownRows.map(\.id) == [newest.id],
                     "The visible filter must leave alerts for another scope enabled")

        let busy = SessionStore(defaults: nil)
        let reviews = (1...13).map { position in
            let completion = now.addingTimeInterval(-Double(position))
            return sample("result-\(position)", .codex, "Review result \(position)", .ready, completion,
                          completedAt: completion)
        }
        busy.ingest(reviews + [blocked], now: now)
        busy.setFilter(.toReview)
        busy.numberEntry = ""
        busy.appendJumpDigit("1")
        busy.appendJumpDigit("2")
        precondition(busy.enteredSession?.id == "result-12" && busy.selectedID == "result-12")
        let justFinished = sample("finished", .cursor, "Just finished", .ready, now, completedAt: now)
        busy.ingest(reviews + [blocked, justFinished], now: now)
        precondition(busy.numberEntry == "12" && busy.enteredSession?.id == "result-11" && busy.selectedID == "result-11",
                     "A live reorder must keep number entry and row selection aligned")
        busy.hide(reviews[0])
        precondition(busy.enteredSession?.id == "result-12" && busy.selectedID == "result-12",
                     "An archive must not move selection away from the entered number")
        busy.setFilter(.all)
        precondition(busy.numberEntry == "" && busy.enteredSession == nil)
        busy.appendJumpDigit("1")
        busy.appendJumpDigit("2")
        busy.setQuery("review result 13")
        precondition(busy.numberEntry == "" && busy.selectedID == "result-13" && busy.session(in: 1)?.id == "result-13")
        busy.setFilter(.needsInput)
        precondition(busy.numberEntry == nil && busy.selectedID == nil && busy.session(in: 1) == nil)
    }

    private static func checkGrouping(now: Date) {
        let store = SessionStore(defaults: nil)
        let olderReply = sample("older-reply", .codex, "Older reply", .ready, now,
                                completedAt: now.addingTimeInterval(-900))
        let newerReply = sample("newer-reply", .cursor, "Newer reply", .ready, now,
                                completedAt: now.addingTimeInterval(-60))
        let input = sample("input", .claude, "Approve deploy", .needsInput, now.addingTimeInterval(-300))
        let slowWorking = sample("slow", .codex, "Slow turn", .working, now.addingTimeInterval(-600))
        let fastWorking = sample("fast", .claude, "Fast turn", .working, now.addingTimeInterval(-30))
        let quiet = sample("quiet", .grok, "Quiet notes", .idle, now.addingTimeInterval(-3_600))
        let fixtures = [olderReply, newerReply, input, slowWorking, fastWorking, quiet]
        store.ingest(fixtures, now: now)
        precondition(store.sections.map(\.group) == [.needsInput, .finished, .working, .quiet])
        precondition(store.shownRows.map(\.id) == [input.id, newerReply.id, olderReply.id, fastWorking.id, slowWorking.id],
                     "Groups should list their rows newest first and start with Quiet folded")
        precondition(store.sidebarItems.first == .header(.needsInput, count: 1, collapsed: false)
                     && store.sidebarItems.last == .header(.quiet, count: 1, collapsed: true))
        precondition(store.nextActionID == input.id && store.session(in: 4)?.id == fastWorking.id)

        let order = store.shownRows.map(\.id)
        store.acknowledge(newerReply)
        precondition(store.shownRows.map(\.id) == order && store.rows.first { $0.id == newerReply.id }?.needsReview == false,
                     "Reading a reply must change how it looks, not where it is")
        let busier = sample(slowWorking.id, .codex, slowWorking.title, .working, now.addingTimeInterval(20))
        store.ingest([olderReply, newerReply, input, busier, fastWorking, quiet], now: now)
        precondition(store.shownRows.map(\.id) == order, "New activity must not reshuffle Working")

        store.ingest([olderReply, newerReply, input, busier, fastWorking, quiet], now: now.addingTimeInterval(9 * 3_600))
        precondition(store.shownRows.map(\.id) == [input.id, olderReply.id, fastWorking.id, slowWorking.id]
                     && store.sections.last?.total == 2,
                     "A read reply should drift to Quiet after eight quiet hours, an unread one should stay")

        store.selectedID = input.id
        precondition(store.selectGroup(forward: true) && store.selectedID == olderReply.id)
        precondition(store.selectGroup(forward: true) && store.selectedID == fastWorking.id)
        precondition(store.selectGroup(forward: true) && store.isQuietHeaderSelected, "⌥↓ should land on folded Quiet")
        precondition(!store.selectGroup(forward: true) && store.navigableIDs.last == SessionGroup.quiet.headerID)
        precondition(store.selectGroup(forward: false) && store.selectedID == fastWorking.id)

        store.setQuery("notes")
        precondition(store.shownRows.map(\.id) == [quiet.id], "Search should look inside folded Quiet")
        store.setQuery(nil)
        store.selectedID = SessionGroup.quiet.headerID
        store.setQuietCollapsed(false)
        precondition(store.isQuietHeaderSelected && store.shownRows.suffix(2).map(\.id) == [newerReply.id, quiet.id])
        store.selectedID = quiet.id
        store.setQuietCollapsed(true)
        precondition(store.isQuietHeaderSelected, "Folding with a quiet chat selected should keep the place on the header")

        let beforeStars = store.sidebarItems
        precondition(store.togglePin(slowWorking) == true && store.togglePin(quiet) == true && store.togglePin(input) == true)
        precondition(store.sidebarItems == beforeStars, "Starring a chat must not move anything in All")
        store.setFilter(.favorites)
        precondition(store.count(for: .favorites) == 3 && store.sections.first?.group == nil
                     && (1...3).compactMap { store.session(in: $0)?.id } == [slowWorking.id, quiet.id, input.id],
                     "The Favorites tab should list stars in the order they were added")
        store.ingest([olderReply, newerReply, sample(input.id, .claude, input.title, .ready, now.addingTimeInterval(30)),
                      busier, fastWorking, quiet], now: now.addingTimeInterval(9 * 3_600))
        precondition((1...3).compactMap { store.session(in: $0)?.id } == [slowWorking.id, quiet.id, input.id],
                     "A favorite's number should hold when its status changes")
        store.ingest([olderReply, newerReply, input, busier, fastWorking, quiet], now: now.addingTimeInterval(9 * 3_600))
        store.setFilter(.all)
        precondition(store.togglePin(quiet) == false && !store.isPinned(quiet.id))

        let full = SessionStore(defaults: nil)
        let chats = (1...(SessionStore.maxPins + 1)).map {
            sample("favorite-\($0)", .codex, "Chat \($0)", .ready, now.addingTimeInterval(-Double($0)))
        }
        full.ingest(chats, now: now)
        precondition(chats.prefix(SessionStore.maxPins).allSatisfy { full.togglePin($0) == true }
                     && full.togglePin(chats[SessionStore.maxPins]) == nil,
                     "Favorites should stop at \(SessionStore.maxPins)")
        store.togglePin(slowWorking)
        store.togglePin(input)

        store.hide(input)
        store.acknowledge(olderReply)
        precondition(store.sidebarItems.first == .allClear && store.nextActionID == nil,
                     "With nothing to act on, the list should say so first")
    }

    private static func checkPalette(now: Date) {
        let suite = "com.relay.sessions.palette-self-test.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { preconditionFailure("Missing test preferences") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SessionStore(defaults: defaults)
        let reply = sample("reply", .codex, "Export retry", .ready, now, completedAt: now)
        let working = sample("working", .claude, "Billing cleanup", .working, now)
        store.ingest([reply, working], now: now)

        store.selectedID = reply.id
        store.openPalette()
        precondition(store.paletteTarget?.id == reply.id && store.selectedPaletteEntry?.action == .command(.open),
                     "The palette should open on the selected chat with Open first")
        precondition(!store.paletteEntries.contains { if case .chat = $0.action { true } else { false } },
                     "Chats appear only once you type")
        store.typeInPalette("billing")
        precondition(store.paletteEntries.map(\.action) == [.chat(working.id)], "Typing a name should find the chat")
        store.deleteInPalette()
        precondition(store.palette?.query == "billin", "Delete should remove one character")
        store.closePalette()

        store.openPalette(choosingLater: true)
        let times = store.paletteEntries
        precondition(times.first?.title == "In an hour" && times.last?.action == .later(nil),
                     "Later until should offer times, ending with no date")
        store.closePalette()

        precondition(store.deferSession(reply, until: now.addingTimeInterval(3_600)))
        precondition(store.count(for: .later) == 1 && store.returnDate(for: reply.id) != nil)
        store.ingest([reply, working], now: now.addingTimeInterval(1_800))
        precondition(store.count(for: .later) == 1, "A chat stays in Later until its time")
        store.ingest([reply, working], now: now.addingTimeInterval(3_700))
        precondition(store.count(for: .later) == 0 && store.rows.first { $0.id == reply.id }?.needsReview == true,
                     "A chat should come back from Later on time, marked unread")
    }

    private static func checkAttentionMarkers(now: Date) {
        let store = SessionStore(defaults: nil)
        let input = sample("input", .claude, "Approve the update", .needsInput, now.addingTimeInterval(-5))
        let earlierInput = sample("earlier-input", .claude, "Approve the migration", .needsInput, now.addingTimeInterval(-35))
        let reply = sample("reply", .codex, "Check the export", .ready, now, completedAt: now.addingTimeInterval(-100))
        var readReply = sample("read-reply", .cursor, "Checked the settings", .ready, now.addingTimeInterval(-10))
        readReply.reviewedBySource = true
        let flagged = sample("flagged", .grok, "Research options", .working, now)
        store.ingest([input, earlierInput, reply, readReply, flagged], now: now)
        store.markUnread(flagged)

        precondition(store.nextActionID == input.id && store.attentionCount == 4)
        precondition(store.latestReplyID == readReply.id, "Latest reply should include read replies and fall back to their update time")
        precondition([input.id, earlierInput.id, readReply.id, reply.id, flagged.id].enumerated()
                        .allSatisfy { store.session(in: $0.offset + 1)?.id == $0.element },
                     "Rows should follow their groups: requests, finished replies, then working, newest first")
        store.markRead(input)
        precondition(store.nextActionID == earlierInput.id && store.session(in: 1)?.id == input.id
                     && store.attentionCount == 4, "Reading moves the next action, not the row")
        precondition(!store.isAttentionPending(for: input), "Reading pending input should still dismiss its nudge")
        store.acknowledge(earlierInput)
        precondition(store.nextActionID == reply.id && store.nextAttention()?.id == reply.id,
                     "An unread reply comes before requests you have already read")
        store.markRead(reply)
        precondition(store.nextActionID == input.id && store.attentionCount == 3)
        precondition(store.nextAttention()?.id == flagged.id, "The global shortcut should still follow the unread queue")

        store.setFilter(.toReview)
        precondition(store.nextActionID == nil && store.latestReplyID == nil && store.attentionCount == 3)
        store.markUnread(reply)
        precondition(store.nextActionID == reply.id && store.latestReplyID == reply.id && store.attentionCount == 4)
        store.setQuery("settings")
        precondition(store.nextActionID == nil && store.latestReplyID == nil)
        store.setFilter(.all)
        precondition(store.nextActionID == nil && store.latestReplyID == readReply.id)
        store.setQuery("")
        store.setFilter(.needsInput)
        precondition(store.nextActionID == input.id && store.latestReplyID == nil && store.count(for: .needsInput) == 2)
        store.setFilter(.all)
        store.hide(input)
        store.hide(earlierInput)
        store.markRead(reply)
        precondition(store.nextActionID == flagged.id && store.latestReplyID == readReply.id && store.attentionCount == 1)
    }

    private static func checkLater(now: Date) {
        let suite = "com.relay.sessions.later-self-test.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { preconditionFailure("Missing test preferences") }
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SessionStore(defaults: defaults)
        let input = sample("z-input", .claude, "Approval requested", .needsInput, now,
                           stateSummary: "Private summary stays in memory.")
        let review = sample("review", .codex, "Review export", .ready, now)
        let working = sample("a-working", .cursor, "Fix layout", .working, now)
        store.ingest([input, review, working], now: now)
        precondition(store.toggleLater(input) == true && store.toggleLater(working) == true)
        precondition(store.count(for: .all) == 1 && store.count(for: .later) == 2 && store.workingCount == 0)
        precondition(store.attentionCount == 1 && store.count(for: .needsInput) == 0 && store.count(for: .toReview) == 1)
        precondition(store.nextAttention()?.id == review.id && !store.isAttentionPending(for: input))

        store.setFilter(.later)
        precondition(store.nextActionID == nil && store.session(in: 1)?.id == input.id
                     && store.session(in: 2)?.id == working.id, "Later should group its rows like All")
        store.setQuery("")
        precondition(store.isSearching && store.query.isEmpty && store.shownRows.count == 2)
        store.setQuery("approval")
        precondition(store.session(in: 1)?.id == input.id && store.removeTarget(allowSelection: true)?.id == input.id)
        store.setQuery(nil)
        precondition(!store.isSearching && store.query.isEmpty && store.shownRows.count == 2)

        let finished = sample(input.id, .claude, input.title, .ready, now, activityID: "finished")
        store.onAttention = { _ in preconditionFailure("Deferred chats must not nudge") }
        store.ingest([finished, review, working], now: now)
        precondition(store.count(for: .toReview) == 1 && !store.isAttentionPending(for: finished))
        store.hide(finished)
        precondition(store.count(for: .later) == 1 && store.undoHide() && store.count(for: .later) == 2)
        precondition(store.toggleLater(finished) == false && store.count(for: .toReview) == 2)
        precondition(store.undoHide() && store.count(for: .later) == 2 && store.count(for: .toReview) == 1)

        let reloaded = SessionStore(defaults: defaults)
        reloaded.ingest([], now: now)
        reloaded.setFilter(.later)
        guard let saved = reloaded.shownRows.first(where: { $0.id == input.id })?.session else {
            preconditionFailure("Deferred chat should survive a missing source")
        }
        precondition(saved.route == input.route && saved.status == .unknown && saved.stateSummary == nil)
        precondition(reloaded.toggleLater(saved) == false)
        reloaded.setFilter(.all)
        precondition(reloaded.session(in: 1) == nil && reloaded.attentionCount == 0,
                     "A restored chat without a live status belongs in folded Quiet")
        reloaded.setQuietCollapsed(false)
        precondition(reloaded.session(in: 1)?.id == input.id)
        precondition(reloaded.undoHide() && reloaded.shownRows.isEmpty && reloaded.count(for: .later) == 2)
    }

    private static func checkArchiveReturns(now: Date) {
        let store = SessionStore(defaults: nil)
        let project = sample("cursor:bc-project", .cursor, "Personal website", .ready, now,
                             completedAt: now.addingTimeInterval(-600))
        let quiet = sample("quiet", .codex, "Quiet chat", .idle, now)
        store.ingest([project, quiet], now: now)
        store.hide(project)
        store.hide(quiet)
        precondition(store.count(for: .archive) == 2 && store.rows.isEmpty)

        let later = now.addingTimeInterval(3_600)
        let touched = sample(quiet.id, .codex, quiet.title, .idle, later)
        store.ingest([project, touched], now: later)
        precondition(store.count(for: .archive) == 2, "Rescanning or touching a chat must not bring it back")

        let finished = sample(project.id, .cursor, project.title, .ready, later, activityID: "turn-2",
                              completedAt: later)
        store.ingest([finished, touched], now: later)
        precondition(store.count(for: .archive) == 1 && store.rows.map(\.id) == [project.id]
                     && store.rows.first?.needsReview == true,
                     "A new finished turn should bring an archived chat back, unread")

        let asking = sample(quiet.id, .codex, quiet.title, .needsInput, later.addingTimeInterval(60))
        store.ingest([finished, asking], now: later.addingTimeInterval(60))
        precondition(store.count(for: .archive) == 0 && store.rows.count == 2,
                     "An agent asking for input should bring its chat back")
    }

    private static func checkArchive(now: Date) {
        let suite = "com.relay.sessions.archive-self-test.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { preconditionFailure("Missing test preferences") }
        defer { defaults.removePersistentDomain(forName: suite) }

        let legacy = sample("legacy", .codex, "Legacy archive", .ready, now)
        let older = now.addingTimeInterval(-60).timeIntervalSinceReferenceDate
        let oldHistory: [String: Any] = ["dismissed": [legacy.id: older, "missing": older], "seen": [:], "links": []]
        defaults.set(try! JSONSerialization.data(withJSONObject: oldHistory), forKey: "sessionHistory")
        let store = SessionStore(defaults: defaults)
        precondition(store.count(for: .archive) == 0 && store.missingArchiveCount == 2)

        let active = (1...20).map { position in
            sample("active-\(position)", .codex, "Archive result \(position)", .ready, now,
                   stateSummary: "The live summary must not be saved.")
        }
        store.ingest(active + [legacy], now: now)
        precondition(store.count(for: .archive) == 1 && store.missingArchiveCount == 1)
        precondition(store.toggleLater(active[0]) == true)
        for session in active { store.hide(session) }
        precondition(store.rows.isEmpty && store.count(for: .later) == 0 && store.count(for: .archive) == 21)
        precondition(store.attentionCount == 0 && store.nextAttention() == nil && !store.isAttentionPending(for: legacy))

        store.setFilter(.archive)
        precondition(store.shownRows.last?.needsReview == true && store.session(in: 21)?.id == legacy.id)
        precondition(store.nextActionID == nil && store.removeTarget(allowSelection: true) == nil)
        store.hide(legacy)
        precondition(store.shownRows.last?.id == legacy.id, "Archiving again must not change archive order")
        precondition(store.undoHide() && store.rows.first?.id == active.last?.id)

        let reloaded = SessionStore(defaults: defaults)
        reloaded.ingest([], now: now)
        reloaded.setFilter(.archive)
        precondition(reloaded.missingArchiveCount == 1 && reloaded.shownRows.count == 20)
        precondition(reloaded.session(id: legacy.id)?.route == legacy.route)
        guard let restored = reloaded.session(id: active[0].id) else { preconditionFailure("Missing archived route") }
        precondition(restored.status == .unknown && restored.stateSummary == nil && restored.route == active[0].route)
        precondition(reloaded.restoreArchived(restored) && reloaded.count(for: .later) == 1)
        precondition(reloaded.count(for: .all) == 0 && reloaded.count(for: .archive) == 19)
    }

    static func checkOverlay(_ overlay: OverlayController, store: SessionStore, missing: [Shortcut]) {
        let now = Date()
        let previousDay = now.addingTimeInterval(-27 * 60 * 60)
        let fixtures = [
            sample("one", .codex, "Review sidebar navigation", .ready, now.addingTimeInterval(-45),
                   completedAt: now.addingTimeInterval(-45),
                   stateSummary: "The sidebar opens on hover and is ready for a final interaction check."),
            sample("two", .claude, "Update integration tests", .needsInput, now,
                   completedAt: now.addingTimeInterval(-180), stateSummary: "Claude is waiting for approval to run the integration tests."),
            sample("three", .cursor, "Fix export layout", .working, now.addingTimeInterval(-600), completedAt: previousDay,
                   stateSummary: "The cloud agent is adjusting export spacing and checking narrow layouts."),
            sample("four", .grok, "Research shortcuts", .idle, previousDay,
                   stateSummary: "The shortcut was tested successfully in full-screen windows."),
            sample("five", .instinct, "Instinct", .unknown, .distantPast),
        ] + (6...14).map { position in
            if position == 6 {
                var read = sample("row-6", .codex, "Check deployment notes", .ready, previousDay,
                                  completedAt: previousDay)
                read.reviewedBySource = true
                return read
            }
            if position == 7 {
                return sample("row-7", .cursor, "Explore sidebar spacing", .idle, now.addingTimeInterval(-2_700))
            }
            let title = position == 13 ? "Check billing report" : "Session \(position)"
            return sample("row-\(position)", .codex, title, .idle, previousDay.addingTimeInterval(-Double(position)),
                          stateSummary: position == 13 ? "The draft lists three invoices still to reconcile." : nil)
        }
        store.ingest(fixtures)
        // The keyboard checks number the quiet rows too, so start with Quiet open.
        store.setQuietCollapsed(false)
        Task {
            let previewDirectory = ProcessInfo.processInfo.environment["RELAY_PREVIEW_DIRECTORY"].map {
                URL(fileURLWithPath: $0)
            }
            precondition(overlay.isEdgeVisible && !overlay.isShowing)
            overlay.show(keyboard: false)
            precondition(overlay.isShowing && !store.keyboardMode)
            overlay.checkHoverArrowInput()
            overlay.close()
            try? await Task.sleep(for: .milliseconds(80))
            overlay.show(keyboard: true)
            try? await Task.sleep(for: .milliseconds(250))
            precondition(overlay.isShowing && store.keyboardMode && store.selectedID == "two")
            overlay.checkLayoutAndKeyInput()
            overlay.checkSidebarDensity()
            precondition(!store.showsAllSummaries, "The default preview should show Compact")
            if let previewDirectory { overlay.renderPreview(in: previewDirectory) }
            overlay.close()
            precondition(!overlay.isShowing && !store.keyboardMode)
            if CommandLine.arguments.contains("--pointer-check") {
                if let hovered = await overlay.checkPointer() {
                    precondition(hovered, "Native hover must reveal the sidebar, support arrow navigation and auto-dismiss")
                    print("Real pointer hover, arrow navigation, rapid reentry and dismiss passed.")
                } else {
                    print("Native pointer test could not post an event.")
                }
                if let dragged = await overlay.checkRailDrag() {
                    precondition(dragged, "Dragging the rail must move the edge handle along the display")
                    print("Real rail drag passed.")
                } else {
                    print("Native rail drag test could not post an event.")
                }
            }
            if CommandLine.arguments.contains("--pointer-check"),
               !missing.contains(.overlay), let toggled = await overlay.checkGlobalToggle() {
                precondition(toggled, "The global shortcut must focus the sidebar without activating Relay")
                print("Real global toggle passed.")
                if !missing.contains(.one) {
                    let filtered = await overlay.checkGlobalFilteredNumber()
                    precondition(filtered, "The global number shortcut must open the displayed filtered row")
                    print("Real global filtered number passed.")
                }
                if !missing.contains(.archive) {
                    let archived = await overlay.checkGlobalArchive()
                    precondition(archived, "The global archive shortcut must remove the selected Relay row")
                    precondition(store.undoHide(), "The archived fixture should be restorable")
                    print("Real global archive and undo passed.")
                }
                overlay.close()
                if !missing.contains(.jumpNumber) {
                    let picked = await overlay.checkGlobalNumberPicker()
                    precondition(picked, "The global number picker shortcut must open number entry")
                    print("Real global number picker passed.")
                    overlay.close()
                }
                if !missing.contains(.details) {
                    let toggledDetails = await overlay.checkGlobalDetailsToggle()
                    precondition(toggledDetails, "The global details shortcut must toggle summary layout")
                    print("Real global details toggle passed.")
                    overlay.close()
                }
            }
            if !UserDefaults.standard.bool(forKey: "muteNudges") {
                store.setFilter(.needsInput)
                var changed = fixtures
                let finishedAt = Date()
                changed[2] = sample("three", .cursor, "Fix export layout", .ready, finishedAt,
                                    activityID: "turn", completedAt: finishedAt)
                store.ingest(changed)
                precondition(overlay.isNudging && !overlay.isShowing,
                             "Completion should nudge with Needs input selected and the sidebar closed")
                precondition(store.rows.first?.id == "three" && !store.shownRows.contains { $0.id == "three" })
                var summary = changed[2]
                summary.stateSummary = "Export spacing is fixed and ready for a narrow-window check."
                store.applySummaries(from: [summary])
                precondition(overlay.nudgeShowsSummary(summary.stateSummary!),
                             "The visible completion nudge should pick up its summary")
                if let previewDirectory { overlay.renderPreview(in: previewDirectory) }
                overlay.clearAttentionNudge()
                summary.stateSummary = "The narrow-window check passed."
                store.applySummaries(from: [summary])
                precondition(!overlay.isNudging, "A late summary should leave a dismissed nudge closed")

                store.setFilter(.toReview)
                changed[2] = sample("three", .cursor, "Fix export layout", .needsInput, Date(),
                                    activityID: "approval", stateSummary: "Choose whether to update the mobile export layout too.")
                store.ingest(changed)
                precondition(!store.shownRows.contains { $0.id == "three" } && overlay.nudgeShowsSummary(changed[2].stateSummary!),
                             "An input nudge should show the decision with To review selected")
                if let previewDirectory { overlay.renderPreview(in: previewDirectory) }
                store.markRead(changed[2])
                precondition(!overlay.isNudging && store.rows.first { $0.id == "three" }?.statusLabel == "Needs input")
                store.setFilter(.all)
            }
            print("Native overlay checks passed. Registered \(Shortcut.allCases.count - missing.count)/\(Shortcut.allCases.count) global shortcuts.")
            if !missing.isEmpty { print("Unavailable: " + missing.map(\.glyph).joined(separator: ", ")) }
            NSApp.terminate(nil)
        }
    }

    static func diagnoseLiveSources() {
        let codex = CodexProvider()
        let claude = ClaudeProvider()
        let desktop = DesktopProvider()
        let summaries = SessionSummaryProvider()
        let includesAutomation = UserDefaults.standard.bool(forKey: SessionStore.automationRunsPreferenceKey)
        let queue = DispatchQueue(label: "Relay.diagnostics", qos: .utility)
        queue.async {
            _ = claude.scan()
            queue.asyncAfter(deadline: .now() + 1.5) {
                let snapshot = codex.scan(includeAutomationRuns: includesAutomation) + claude.scan() + desktop.scan()
                _ = summaries.annotate(snapshot)
                queue.asyncAfter(deadline: .now() + 13) {
                    let sessions = summaries.annotate(snapshot)
                    DispatchQueue.main.async {
                        for source in Source.allCases {
                            let group = sessions.filter { $0.source == source }
                            let statuses = Dictionary(grouping: group, by: \.status).mapValues(\.count)
                            let report = statuses.sorted { $0.key.rawValue < $1.key.rawValue }
                                .map { "\($0.key.rawValue)=\($0.value)" }.joined(separator: ", ")
                            let routes = group.filter { session in
                                if case .url(let url) = session.route, let address = URL(string: url) {
                                    return NSWorkspace.shared.urlForApplication(toOpen: address) != nil
                                }
                                return true
                            }
                            let count = group.filter { $0.stateSummary != nil }.count
                            let generated = summaries.generatedCount(in: group)
                            print("\(source.name): \(group.count) sessions, \(routes.count) routes available, \(count) summaries (\(generated) generated locally)" +
                                (report.isEmpty ? "" : " (\(report))"))
                        }
                        Task {
                            await summaries.shutdown()
                            NSApp.terminate(nil)
                        }
                    }
                }
            }
        }
    }

    private static func sample(_ id: String, _ source: Source, _ title: String,
                               _ status: SessionStatus, _ now: Date, activityID: String? = nil,
                               completedAt: Date? = nil, stateSummary: String? = nil) -> Session {
        Session(id: id, source: source, title: title, status: status, updatedAt: now,
                route: .url("https://example.com"), activityID: activityID, completedAt: completedAt,
                stateSummary: stateSummary)
    }
}
