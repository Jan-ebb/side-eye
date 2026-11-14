import Foundation

/// Everything the ⌘K palette can do. Each command shows its own key, so the palette teaches the shortcuts.
enum PaletteCommand: String, CaseIterable {
    case open, archive, later, laterUntil, pin, read, restore
    case previews, archiveRead, showAll, showFavorites, showLater, archiveList, jump, search, undo, settings
}

struct PaletteState: Equatable {
    var query = ""
    var index = 0
    /// The chat the actions apply to: the one selected when the palette opened.
    var targetID: String?
    /// True while choosing when a chat comes back from Later.
    var choosingLater = false
}

struct PaletteEntry: Identifiable, Equatable {
    enum Action: Equatable {
        case command(PaletteCommand)
        case chat(String)
        case later(Date?)
    }

    enum Icon: Equatable {
        case symbol(String)
        case source(Source)
    }

    let id: String
    let section: String
    let title: String
    var detail: String?
    var key: String?
    let icon: Icon
    var group: SessionGroup?
    let action: Action
    var keywords = ""
}

extension SessionStore {
    var paletteTarget: SessionRow? {
        guard let id = palette?.targetID else { return nil }
        return shownRows.first { $0.id == id } ?? rows.first { $0.id == id }
    }

    func openPalette(choosingLater: Bool = false) {
        let target = shownRows.first { $0.id == selectedID }?.id
        palette = PaletteState(targetID: target, choosingLater: choosingLater && target != nil)
    }

    func closePalette() { palette = nil }

    func showLaterTimes() {
        guard var state = palette, state.targetID != nil else { return }
        state.choosingLater = true
        state.query = ""
        state.index = 0
        palette = state
    }

    func typeInPalette(_ text: String) {
        guard var state = palette else { return }
        state.query = String((state.query + text).prefix(80))
        state.index = 0
        palette = state
    }

    /// Deletes a character, or steps back from the Later times when the query is already empty.
    func deleteInPalette() {
        guard var state = palette else { return }
        if state.query.isEmpty {
            if state.choosingLater { state.choosingLater = false } else { return }
        } else {
            state.query.removeLast()
        }
        state.index = 0
        palette = state
    }

    func movePaletteSelection(by step: Int) {
        guard var state = palette else { return }
        let count = paletteEntries.count
        guard count > 0 else { return }
        state.index = max(0, min(count - 1, state.index + step))
        palette = state
    }

    var selectedPaletteEntry: PaletteEntry? {
        guard let palette else { return nil }
        let entries = paletteEntries
        return entries.indices.contains(palette.index) ? entries[palette.index] : nil
    }

    var paletteEntries: [PaletteEntry] {
        guard let palette else { return [] }
        let entries = palette.choosingLater
            ? laterEntries(now: Date())
            : targetEntries + commandEntries + chatEntries(listingAll: !palette.query.isEmpty)
        let terms = palette.query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return entries }
        // Best matches first: a title that starts with what you typed, then word starts, then anywhere,
        // then hidden keywords. Sections stay together, ordered by their best match.
        let scored = entries.enumerated().compactMap { offset, entry -> (score: Int, offset: Int, entry: PaletteEntry)? in
            let text = entry.title + " " + entry.keywords
            guard terms.allSatisfy({ text.localizedStandardContains($0) }) else { return nil }
            return (Self.matchScore(entry.title, terms: terms), offset, entry)
        }
        var sectionScore: [String: Int] = [:]
        var sectionFirst: [String: Int] = [:]
        for item in scored {
            sectionScore[item.entry.section] = min(sectionScore[item.entry.section] ?? .max, item.score)
            sectionFirst[item.entry.section] = min(sectionFirst[item.entry.section] ?? .max, item.offset)
        }
        return scored.sorted { a, b in
            let sectionA = a.entry.section, sectionB = b.entry.section
            if sectionA != sectionB {
                let scoreA = sectionScore[sectionA] ?? 0, scoreB = sectionScore[sectionB] ?? 0
                return scoreA != scoreB ? scoreA < scoreB : (sectionFirst[sectionA] ?? 0) < (sectionFirst[sectionB] ?? 0)
            }
            return a.score != b.score ? a.score < b.score : a.offset < b.offset
        }.map(\.entry)
    }

    static func matchScore(_ title: String, terms: [String]) -> Int {
        let title = title.lowercased()
        if title.hasPrefix(terms.joined(separator: " ")) { return 0 }
        let words = title.split { !$0.isLetter && !$0.isNumber }
        if terms.allSatisfy({ term in words.contains { $0.hasPrefix(term) } }) { return 1 }
        if terms.allSatisfy({ title.contains($0) }) { return 2 }
        return 3
    }

    private var targetEntries: [PaletteEntry] {
        guard let row = paletteTarget else { return [] }
        let section = "For “\(row.session.title)”"
        func entry(_ command: PaletteCommand, _ title: String, key: String?, symbol: String,
                   keywords: String = "") -> PaletteEntry {
            PaletteEntry(id: "target-" + command.rawValue, section: section, title: title, key: key,
                         icon: .symbol(symbol), action: .command(command), keywords: keywords)
        }
        var entries = [entry(.open, "Open", key: "↵", symbol: "arrow.up.right", keywords: "switch go")]
        if filter == .archive {
            return entries + [entry(.restore, "Restore", key: "R", symbol: "arrow.uturn.backward",
                                    keywords: "unarchive inbox back")]
        }
        // Favorites is a lasting list; archiving and Later only apply to the Inbox.
        if filter != .favorites {
            entries += [
                entry(.archive, "Archive", key: "E", symbol: "archivebox", keywords: "done remove"),
                entry(.later, filter == .later ? "Move back to Inbox" : "Move to Later", key: "L", symbol: "clock",
                      keywords: "snooze defer"),
                entry(.laterUntil, "Later until…", key: "H", symbol: "alarm", keywords: "snooze remind time"),
            ]
        }
        entries += [
            entry(.pin, isPinned(row.id) ? "Unfavorite" : "Favorite", key: "F", symbol: "star",
                  keywords: "favorites pin star keep add remove"),
            entry(.read, row.needsReview ? "Mark as read" : "Mark as unread", key: "⌘U", symbol: "circlebadge",
                  keywords: "unread seen"),
        ]
        return entries
    }

    private var commandEntries: [PaletteEntry] {
        func entry(_ command: PaletteCommand, _ title: String, key: String?, symbol: String,
                   keywords: String = "") -> PaletteEntry {
            PaletteEntry(id: "command-" + command.rawValue, section: "Commands", title: title, key: key,
                         icon: .symbol(symbol), action: .command(command), keywords: keywords)
        }
        var entries = [
            entry(.previews, showsAllSummaries ? "Hide previews" : "Show previews", key: "D", symbol: "text.alignleft",
                  keywords: "summary briefing"),
            entry(.archiveList, "Go to Archive", key: nil, symbol: "arrow.right", keywords: "show archived restore"),
            entry(.jump, "Jump to row", key: "0", symbol: "number", keywords: "number row go"),
            entry(.search, "Search chats", key: "/", symbol: "magnifyingglass", keywords: "find filter"),
            entry(.settings, "Settings", key: "⌘,", symbol: "gearshape", keywords: "preferences shortcuts"),
        ]
        // The other tabs; the next one shows Tab, the key that gets there. Going somewhere has one
        // icon, so a star, clock or archive box always means acting on a chat.
        let tabs = SessionFilter.tabs
        let next = tabs.firstIndex(of: filter).map { tabs[($0 + 1) % tabs.count] } ?? .all
        let tabCommands: [(SessionFilter, PaletteCommand)] = [
            (.all, .showAll), (.favorites, .showFavorites), (.later, .showLater),
        ]
        entries.insert(contentsOf: tabCommands.filter { $0.0 != filter }.map { tab, command in
            entry(command, "Go to \(tab.label)", key: tab == next ? "Tab" : nil, symbol: "arrow.right",
                  keywords: "tab list show")
        }, at: 1)
        if filter == .all, readReplyCount > 0 {
            entries.insert(entry(.archiveRead, "Archive all read", key: "⇧E", symbol: "archivebox",
                                 keywords: "done clear inbox zero"), at: 0)
        }
        if canUndo {
            entries.insert(entry(.undo, "Undo", key: "Z", symbol: "arrow.uturn.backward", keywords: "back revert"),
                           at: 0)
        }
        return entries
    }

    /// Chats appear once you start typing, so the palette doubles as the fastest way to switch.
    private func chatEntries(listingAll: Bool) -> [PaletteEntry] {
        guard listingAll else { return [] }
        // No row numbers here: digits type into the palette, so a number would be a key that does nothing.
        return rows.map { row in
            return PaletteEntry(id: "chat-" + row.id, section: "Chats", title: row.session.title,
                                detail: row.session.source.name,
                                icon: .source(row.session.source), group: SessionGroup(row),
                                action: .chat(row.id),
                                keywords: [row.session.source.name, row.session.detail, row.statusLabel]
                                    .joined(separator: " "))
        }
    }

    private func laterEntries(now: Date) -> [PaletteEntry] {
        let section = paletteTarget.map { "Bring back “\($0.session.title)”" } ?? "Bring back"
        return Self.laterTimes(now: now).map { option in
            PaletteEntry(id: "later-" + option.title, section: section, title: option.title,
                         detail: option.date.map { Self.describe($0, now: now) }, icon: .symbol("clock"),
                         action: .later(option.date), keywords: option.keywords)
        }
    }

    static func laterTimes(now: Date, calendar: Calendar = .current) -> [(title: String, date: Date?, keywords: String)] {
        var options: [(title: String, date: Date?, keywords: String)] = [
            ("In an hour", now.addingTimeInterval(3_600), "1h hour soon"),
        ]
        if let evening = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: now),
           evening.timeIntervalSince(now) > 3_600 {
            options.append(("This evening", evening, "tonight 6pm"))
        }
        let startOfToday = calendar.startOfDay(for: now)
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday),
           let morning = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) {
            options.append(("Tomorrow morning", morning, "tomorrow 9am"))
            if var monday = calendar.nextDate(after: now, matching: DateComponents(hour: 9, minute: 0, weekday: 2),
                                              matchingPolicy: .nextTime) {
                if calendar.isDate(monday, inSameDayAs: morning),
                   let later = calendar.date(byAdding: .day, value: 7, to: monday) { monday = later }
                options.append(("Next week", monday, "monday week"))
            }
        }
        options.append(("Until I move it back", nil, "no date someday manual"))
        return options
    }

    static func describe(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(.dateTime.hour().minute()) }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}
