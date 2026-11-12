import AppKit
import Darwin
import Foundation

final class ClaudeProvider: @unchecked Sendable {
    private struct RegistryEntry: Decodable {
        let pid: Int32
        let sessionId: String
        let cwd: String
        let startedAt: Int64
        let procStart: String?
        let kind: String?
        let entrypoint: String?
        let hostSessionId: String?
        let name: String?
        let status: String?
        let statusUpdatedAt: Int64?
    }

    private struct DesktopEntry: Decodable {
        let title: String?
        let isArchived: Bool?
        let completedTurns: Int?
        let lastTurnEdgeAt: Int64?
        let lastFocusedAt: Int64?
        let interruptedAwaitingPerson: Bool?
        let lastTurnCutShort: Bool?
        let lastTurnStopped: Bool?
        let errorAt: Int64?
    }

    private struct AgentEntry: Decodable, Sendable {
        let id: String?
        let kind: String
        let cwd: String
        let startedAt: Int64
        let sessionId: String?
        let name: String?
        let pid: Int32?
        let state: String?
        let status: String?
    }

    private struct DesktopCache {
        let url: URL
        let modifiedAt: Date?
        let entry: DesktopEntry
    }

    private let home: URL
    private let registry: URL
    private let desktopRoot: URL
    private var desktopCache: [String: DesktopCache] = [:]
    private var lastSessions: [String: Session] = [:]
    private let cliLock = NSLock()
    private var cliEntries: [AgentEntry] = []
    private var cliRefreshInProgress = false
    private var lastCLIRefresh = Date.distantPast
    private var lastCLISuccess = Date.distantPast

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
        let config = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            .flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil }
            ?? home.appendingPathComponent(".claude", isDirectory: true)
        registry = config.appendingPathComponent("sessions", isDirectory: true)
        desktopRoot = home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions",
                                                   isDirectory: true)
    }

    func scan() -> [Session] {
        let now = Date()
        let agents = cachedAgents(at: now)
        let entries = registryEntries()
        var sessions: [String: Session] = [:]

        for entry in entries {
            guard let process = Self.processInfo(entry.pid), Self.isSameProcess(process, entry: entry) else {
                continue
            }

            let desktopID = entry.entrypoint == "claude-desktop" ? entry.hostSessionId : nil
            let desktop = desktopID.flatMap(desktopEntry(for:))
            if desktop?.isArchived == true { continue }
            let id = "claude:" + (desktopID ?? entry.sessionId)
            let previous = lastSessions[id]
            let tty = Self.terminalDevice(process)
            let agent = agents.first { $0.pid == entry.pid && $0.sessionId == entry.sessionId }
            let rawStatus = entry.status ?? agent?.status
            let status: SessionStatus
            if let agent, agent.kind == "background" {
                status = Self.backgroundStatus(agent)
            } else {
                status = Self.interactiveStatus(rawStatus, desktop: desktop, previous: previous)
            }
            let statusEdge = entry.statusUpdatedAt ?? entry.startedAt
            let edge = status == .ready && statusEdge - entry.startedAt < 1_500
                ? desktop?.lastTurnEdgeAt ?? statusEdge : statusEdge
            let observedCompletion = previous?.status == .working || previous?.status == .needsInput
            let hasCompletionEdge = statusEdge - entry.startedAt >= 1_500 ||
                desktop?.lastTurnEdgeAt != nil || observedCompletion
            let didComplete = status == .ready && hasCompletionEdge &&
                desktop?.lastTurnCutShort != true && desktop?.lastTurnStopped != true &&
                (desktop?.errorAt ?? 0) < edge

            let route: Route
            if let desktopID, let url = Self.desktopRoute(desktopID) {
                route = .url(url)
            } else if let agent, agent.kind == "background", let backgroundID = agent.id,
                      Self.validBackgroundID(backgroundID) {
                route = .claudeBackground(id: backgroundID, directory: entry.cwd)
            } else if tty != nil {
                route = .claude(sessionID: entry.sessionId, directory: entry.cwd, tty: tty)
            } else {
                continue
            }

            let reviewed: Bool?
            if status == .ready, let focused = desktop?.lastFocusedAt,
               statusEdge - entry.startedAt >= 1_500 || desktop?.lastTurnEdgeAt != nil {
                reviewed = focused >= edge
            } else {
                reviewed = nil
            }
            sessions[id] = Session(id: id, source: .claude,
                                   title: Self.title(desktop?.title ?? entry.name, directory: entry.cwd),
                                   detail: Self.detail(entry.cwd, desktop: desktopID != nil,
                                                       background: agent?.kind == "background"),
                                   status: status, updatedAt: Self.date(edge), route: route,
                                   activityID: "\(entry.pid):\(edge)", reviewedBySource: reviewed,
                                   completedAt: didComplete ? Self.date(edge) : nil)
        }

        for agent in agents {
            if let sessionID = agent.sessionId, sessions["claude:" + sessionID] != nil { continue }
            if let pid = agent.pid, entries.contains(where: { $0.pid == pid }) { continue }

            if agent.kind == "background", let backgroundID = agent.id, Self.validBackgroundID(backgroundID) {
                let id = "claude:" + (agent.sessionId ?? "background:" + backgroundID)
                let status = Self.backgroundStatus(agent)
                let previous = lastSessions[id]
                if agent.state == "stopped" { continue }
                if agent.state == "done" || agent.state == "failed" {
                    let lastActivity = previous?.updatedAt ?? Self.date(agent.startedAt)
                    guard lastActivity >= now.addingTimeInterval(-6 * 60 * 60) else { continue }
                }
                let changed = previous.map { $0.status != status } ?? false
                let updatedAt = changed ? now : previous?.updatedAt ?? Self.date(agent.startedAt)
                sessions[id] = Session(id: id, source: .claude, title: Self.title(agent.name, directory: agent.cwd),
                                       detail: Self.detail(agent.cwd, desktop: false, background: true),
                                       status: status, updatedAt: updatedAt,
                                       route: .claudeBackground(id: backgroundID, directory: agent.cwd),
                                       activityID: String(updatedAt.timeIntervalSince1970),
                                       completedAt: changed && status == .ready ? updatedAt : nil)
            } else if let pid = agent.pid, let sessionID = agent.sessionId, UUID(uuidString: sessionID) != nil,
                      let process = Self.processInfo(pid),
                      let tty = Self.terminalDevice(process),
                      Self.isClaudeProcess(pid),
                      abs(Double(process.pbi_start_tvsec) - Double(agent.startedAt) / 1_000) < 30 {
                let id = "claude:" + sessionID
                let previous = lastSessions[id]
                let status = Self.interactiveStatus(agent.status, desktop: nil, previous: previous)
                let changed = previous.map { $0.status != status } ?? false
                let updatedAt = changed ? now : previous?.updatedAt ?? Self.date(agent.startedAt)
                sessions[id] = Session(id: id, source: .claude, title: Self.title(agent.name, directory: agent.cwd),
                                       detail: Self.detail(agent.cwd, desktop: false),
                                       status: status, updatedAt: updatedAt,
                                       route: .claude(sessionID: sessionID, directory: agent.cwd, tty: tty),
                                       activityID: String(updatedAt.timeIntervalSince1970),
                                       completedAt: changed && status == .ready ? updatedAt : nil)
            }
        }

        let liveIDs = Set(entries.compactMap(\.hostSessionId))
        desktopCache = desktopCache.filter { liveIDs.contains($0.key) }
        lastSessions = sessions
        return Array(sessions.values)
    }

    private func registryEntries() -> [RegistryEntry] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: registry,
                      includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { url in
            guard url.pathExtension == "json",
                  let pid = Int32(url.deletingPathExtension().lastPathComponent), pid > 1,
                  let entry = Self.read(RegistryEntry.self, from: url, maximumSize: 64 * 1_024),
                  entry.pid == pid, UUID(uuidString: entry.sessionId) != nil,
                  entry.kind == nil || entry.kind == "interactive" || entry.kind == "background" else { return nil }
            return entry
        }
    }

    private func desktopEntry(for id: String) -> DesktopEntry? {
        guard Self.desktopRoute(id) != nil else { return nil }
        let url: URL?
        if let existing = desktopCache[id]?.url, FileManager.default.fileExists(atPath: existing.path) {
            url = existing
        } else {
            let fileManager = FileManager.default
            let accounts = (try? fileManager.contentsOfDirectory(at: desktopRoot,
                             includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            url = accounts.lazy.flatMap { account in
                (try? fileManager.contentsOfDirectory(at: account, includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles])) ?? []
            }.lazy.map { $0.appendingPathComponent(id).appendingPathExtension("json") }
                .first { fileManager.fileExists(atPath: $0.path) }
        }
        guard let url else { return nil }
        let modifiedAt = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if let old = desktopCache[id], modifiedAt != nil, old.modifiedAt == modifiedAt { return old.entry }
        guard let entry = Self.read(DesktopEntry.self, from: url, maximumSize: 2 * 1_024 * 1_024) else {
            return desktopCache[id]?.entry
        }
        desktopCache[id] = DesktopCache(url: url, modifiedAt: modifiedAt, entry: entry)
        return entry
    }

    private func cachedAgents(at now: Date) -> [AgentEntry] {
        cliLock.lock()
        defer { cliLock.unlock() }
        if !cliRefreshInProgress && now.timeIntervalSince(lastCLIRefresh) >= 8 {
            lastCLIRefresh = now
            cliRefreshInProgress = true
            let executable = Self.claudeExecutable(in: home)
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let entries = executable.flatMap {
                    Self.command($0, ["agents", "--json", "--all"], timeout: 2,
                                 outputLimit: 2 * 1_024 * 1_024)
                }.flatMap { try? JSONDecoder().decode([AgentEntry].self, from: $0) }
                guard let self else { return }
                self.cliLock.lock()
                if let entries {
                    self.cliEntries = entries
                    self.lastCLISuccess = Date()
                }
                self.cliRefreshInProgress = false
                self.cliLock.unlock()
            }
        }
        return now.timeIntervalSince(lastCLISuccess) < 30 ? cliEntries : []
    }

    private static func interactiveStatus(_ raw: String?, desktop: DesktopEntry?,
                                          previous: Session?) -> SessionStatus {
        switch raw {
        case "busy", "working": return .working
        case "waiting", "blocked": return .needsInput
        case "idle":
            if desktop?.interruptedAwaitingPerson == true { return .needsInput }
            if (desktop?.completedTurns ?? 0) > 0 ||
                previous?.status == .working || previous?.status == .needsInput || previous?.status == .ready {
                return .ready
            }
            return .idle
        default: return .unknown
        }
    }

    private static func backgroundStatus(_ entry: AgentEntry) -> SessionStatus {
        if entry.status == "waiting" || entry.state == "blocked" { return .needsInput }
        if entry.status == "busy" || entry.state == "working" { return .working }
        if entry.state == "done" { return .ready }
        if entry.state == "failed" { return .needsInput }
        if entry.status == "idle" { return .idle }
        return .unknown
    }

    private static func desktopRoute(_ id: String) -> String? {
        guard id.range(of: #"^local_[A-Za-z0-9-]{1,64}$"#, options: .regularExpression) != nil else { return nil }
        // Claude Desktop generates this same route for Spotlight and its Continue menu.
        return "claude://code/continue?session=" + id
    }

    private static func validBackgroundID(_ id: String) -> Bool {
        id.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]{0,95}$"#, options: .regularExpression) != nil
    }

    private static func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }

    private static func title(_ name: String?, directory: String) -> String {
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return String(name.prefix(200))
        }
        let folder = URL(fileURLWithPath: directory, isDirectory: true).lastPathComponent
        return folder.isEmpty || folder == "/" ? "Claude Code" : folder
    }

    private static func detail(_ directory: String, desktop: Bool, background: Bool = false) -> String {
        let folder = URL(fileURLWithPath: directory, isDirectory: true).lastPathComponent
        let origin = desktop ? "Desktop" : background ? "Background agent" : "Terminal"
        return folder.isEmpty || folder == "/" ? origin : "\(origin)  ·  \(folder)"
    }

    private static func read<T: Decodable>(_ type: T.Type, from url: URL, maximumSize: Int) -> T? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size > 0, size <= maximumSize,
              let data = try? Data(contentsOf: url), data.count <= maximumSize else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func processInfo(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let length = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, length) == length,
              info.pbi_uid == getuid(), info.pbi_status != SZOMB else { return nil }
        return info
    }

    private static func isSameProcess(_ process: proc_bsdinfo, entry: RegistryEntry) -> Bool {
        guard isClaudeProcess(entry.pid) else { return false }
        if let start = entry.procStart {
            // Claude records the process start using ps with LC_ALL=C and TZ=UTC.
            let normalized = start.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let actual = processStartFormatter.string(from: Date(timeIntervalSince1970: Double(process.pbi_start_tvsec)))
            return actual == normalized
        }
        return abs(Double(process.pbi_start_tvsec) - Double(entry.startedAt) / 1_000) < 120
    }

    private static let processStartFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter
    }()

    private static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0, let end = buffer.firstIndex(of: 0) else { return nil }
        return String(decoding: buffer.prefix(end).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func isClaudeProcess(_ pid: Int32) -> Bool {
        guard let path = executablePath(pid) else { return false }
        return URL(fileURLWithPath: path).lastPathComponent.lowercased() == "claude" ||
            path.contains("/.local/share/claude/versions/")
    }

    private static func terminalDevice(_ process: proc_bsdinfo) -> String? {
        guard process.e_tdev != UInt32.max,
              let device = devname(Int32(bitPattern: process.e_tdev), mode_t(S_IFCHR)) else { return nil }
        return "/dev/" + String(cString: device)
    }

    private static func claudeExecutable(in home: URL) -> URL? {
        let paths = [home.appendingPathComponent(".local/bin/claude").path,
                     "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        if let path = paths.first(where: FileManager.default.isExecutableFile(atPath:)) {
            return URL(fileURLWithPath: path)
        }
        let versions = home.appendingPathComponent("Library/Application Support/Claude/claude-code")
        let folders = (try? FileManager.default.contentsOfDirectory(at: versions, includingPropertiesForKeys: nil)) ?? []
        for version in folders.sorted(by: { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }) {
            let builds = (try? FileManager.default.contentsOfDirectory(at: version, includingPropertiesForKeys: nil)) ?? []
            for build in builds {
                let executable = build.appendingPathComponent("claude.app/Contents/MacOS/claude")
                if FileManager.default.isExecutableFile(atPath: executable.path) { return executable }
            }
        }
        return nil
    }

    private static func command(_ executable: URL, _ arguments: [String], timeout: TimeInterval,
                                outputLimit: Int) -> Data? {
        let process = Process()
        let pipe = Pipe()
        let completion = DispatchSemaphore(value: 0)
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in completion.signal() }
        do { try process.run() } catch { return nil }
        try? pipe.fileHandleForWriting.close()
        defer {
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            try? pipe.fileHandleForReading.close()
        }

        // Drain while the process runs and stop at the deadline even if a descendant holds the pipe open.
        let expiry = DispatchTime.now() + timeout
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 32 * 1_024)
        var output = Data()
        while DispatchTime.now() < expiry {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < expiry.uptimeNanoseconds else { return nil }
            let remaining = Int32((expiry.uptimeNanoseconds - now + 999_999) / 1_000_000)
            var watch = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let available = Darwin.poll(&watch, 1, remaining)
            if available < 0 && errno == EINTR { continue }
            guard available > 0 else { return nil }
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            if count == 0 {
                guard completion.wait(timeout: expiry) == .success, process.terminationStatus == 0 else { return nil }
                return output
            }
            guard count > 0, output.count + count <= outputLimit else { return nil }
            output.append(contentsOf: buffer.prefix(count))
        }
        return nil
    }

    @MainActor
    static func jump(sessionID: String, directory _: String, tty: String?) -> Bool {
        guard UUID(uuidString: sessionID) != nil, let tty,
              tty.range(of: #"^/dev/ttys?[A-Za-z0-9]+$"#, options: .regularExpression) != nil,
              let pid = liveInteractivePID(sessionID: sessionID, tty: tty) else { return false }
        if let bundleID = owningTerminal(pid: pid) {
            return focusTerminal(tty: tty, owningBundle: bundleID)
        }
        if let outerTTY = selectTmuxPane(tty: tty) {
            return focusTerminal(tty: outerTTY, owningBundle: nil)
        }
        return focusTerminal(tty: tty, owningBundle: nil)
    }

    private static func liveInteractivePID(sessionID: String, tty: String) -> Int32? {
        let provider = ClaudeProvider()
        if let entry = provider.registryEntries().first(where: { $0.sessionId == sessionID }),
           let process = processInfo(entry.pid), isSameProcess(process, entry: entry),
           terminalDevice(process) == tty { return entry.pid }

        guard let executable = claudeExecutable(in: provider.home),
              let data = command(executable, ["agents", "--json"], timeout: 0.6, outputLimit: 2 * 1_024 * 1_024),
              let entries = try? JSONDecoder().decode([AgentEntry].self, from: data),
              let pid = entries.first(where: { $0.sessionId == sessionID })?.pid,
              let process = processInfo(pid), isClaudeProcess(pid),
              terminalDevice(process) == tty else { return nil }
        return pid
    }

    @MainActor
    private static func owningTerminal(pid: Int32) -> String? {
        let known = ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty"]
        var current = pid
        for _ in 0..<12 {
            guard let process = processInfo(current), process.pbi_ppid > 1 else { return nil }
            current = Int32(process.pbi_ppid)
            if let bundle = NSRunningApplication(processIdentifier: current)?.bundleIdentifier,
               known.contains(bundle) { return bundle }
        }
        return nil
    }

    @MainActor
    static func jumpBackground(id: String, directory: String) -> Bool {
        guard validBackgroundID(id), directory.hasPrefix("/"),
              let executable = claudeExecutable(in: FileManager.default.homeDirectoryForCurrentUser) else {
            return false
        }
        let command = "cd -- " + shellQuote(directory) + " && exec " + shellQuote(executable.path) +
            " attach " + shellQuote(id)
        return runAppleScript("""
            tell application id "com.apple.Terminal"
                do script \(appleScriptQuote(command))
                activate
                return true
            end tell
            """)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func appleScriptQuote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r") + "\""
    }

    @MainActor
    private static func focusTerminal(tty: String, owningBundle: String?) -> Bool {
        let target = appleScriptQuote(tty)
        let isCandidate: (String) -> Bool = {
            (owningBundle == nil || owningBundle == $0) &&
                !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
        }

        if isCandidate("com.apple.Terminal"),
           runAppleScript("""
               tell application id "com.apple.Terminal"
                   repeat with terminalWindow in windows
                       repeat with terminalTab in tabs of terminalWindow
                           if tty of terminalTab is \(target) then
                               set selected of terminalTab to true
                               set miniaturized of terminalWindow to false
                               set frontmost of terminalWindow to true
                               activate
                               return true
                           end if
                       end repeat
                   end repeat
               end tell
               return false
               """) { return true }

        if isCandidate("com.googlecode.iterm2"),
           runAppleScript("""
               tell application id "com.googlecode.iterm2"
                   repeat with terminalWindow in windows
                       repeat with terminalTab in tabs of terminalWindow
                           repeat with terminalSession in sessions of terminalTab
                               if tty of terminalSession is \(target) then
                                   select terminalWindow
                                   select terminalTab
                                   select terminalSession
                                   activate
                                   return true
                               end if
                           end repeat
                       end repeat
                   end repeat
               end tell
               return false
               """) { return true }

        guard isCandidate("com.mitchellh.ghostty"),
              let ghostty = NSRunningApplication.runningApplications(withBundleIdentifier: "com.mitchellh.ghostty").first,
              let url = ghostty.bundleURL,
              let version = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              version.compare("1.4", options: .numeric) != .orderedAscending else {
            return false
        }
        return runAppleScript("""
            tell application id "com.mitchellh.ghostty"
                repeat with terminalSurface in terminals
                    if tty of terminalSurface is \(target) then
                        focus terminalSurface
                        return true
                    end if
                end repeat
            end tell
            return false
            """)
    }

    @MainActor
    private static func runAppleScript(_ source: String) -> Bool {
        let bounded = "with timeout of 3 seconds\n" + source + "\nend timeout"
        guard let script = NSAppleScript(source: bounded) else { return false }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        return error == nil && result.booleanValue
    }

    private static func selectTmuxPane(tty: String) -> String? {
        let binaries = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"]
        guard let path = binaries.first(where: FileManager.default.isExecutableFile(atPath:)) else { return nil }
        let executable = URL(fileURLWithPath: path)
        // The built-in server's list exposes the pane's own TTY and the outer client TTY.
        guard let paneData = command(executable, ["list-panes", "-a", "-F",
                                     "#{pane_tty} #{pane_id} #{window_id} #{session_id}"],
                                     timeout: 0.35, outputLimit: 64 * 1_024),
              let pane = String(decoding: paneData, as: UTF8.self).split(separator: "\n")
                .map({ $0.split(separator: " ").map(String.init) })
                .first(where: { $0.count == 4 && $0[0] == tty }),
              let clientData = command(executable, ["list-clients", "-F", "#{client_tty} #{client_activity}"],
                                       timeout: 0.35, outputLimit: 64 * 1_024) else { return nil }
        let clientLines = String(decoding: clientData, as: UTF8.self).split(separator: "\n")
        let clients: [(tty: String, activity: Int64)] = clientLines.compactMap { line in
            let fields = line.split(separator: " ")
            guard fields.count == 2, fields[0].hasPrefix("/dev/tty"),
                  let activity = Int64(fields[1]) else { return nil }
            return (String(fields[0]), activity)
        }
        guard let client = clients.max(by: { $0.activity < $1.activity }) else { return nil }
        let actions = ["switch-client", "-c", client.tty, "-t", pane[3], ";",
                       "select-window", "-t", pane[2], ";", "select-pane", "-t", pane[1]]
        guard command(executable, actions, timeout: 0.35, outputLimit: 4 * 1_024) != nil else { return nil }
        return client.tty
    }
}
