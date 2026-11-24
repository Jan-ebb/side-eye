import Darwin
import Foundation
import NaturalLanguage

/// A warm, app-owned model worker. Conversation data travels over a private Unix socket.
actor LocalSummaryEngine {
    static let modelFileName = "SideEyeSummary"
    private static let maximumSummaryLength = 135
    private static let idleSeconds: Double = 45
    /// llama.cpp's server, where Homebrew puts it on Apple silicon or on Intel.
    private static let serverURL = ["/opt/homebrew/bin/llama-server", "/usr/local/bin/llama-server"]
        .map { URL(fileURLWithPath: $0) }
        .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        ?? URL(fileURLWithPath: "/opt/homebrew/bin/llama-server")
    private let modelURL: URL?
    private let serverURL: URL
    private let workerSlot = WorkerSlot()
    private var idleTask: Task<Void, Never>?
    private var activeRequests = 0
    private var unavailableUntil = Date.distantPast

    init(modelURL: URL? = Bundle.main.url(forResource: LocalSummaryEngine.modelFileName,
                                         withExtension: "gguf", subdirectory: "Models"),
         serverURL: URL = LocalSummaryEngine.serverURL) {
        self.modelURL = modelURL
        self.serverURL = serverURL
    }

    nonisolated static var isInstalled: Bool {
        let model = Bundle.main.url(forResource: modelFileName, withExtension: "gguf", subdirectory: "Models")
        return model != nil && FileManager.default.isExecutableFile(atPath: serverURL.path)
    }

    func summarize(status: SessionStatus, title: String, evidence: SessionEvidence) async -> String? {
        guard !Task.isCancelled, Date() >= unavailableUntil,
              let modelURL, FileManager.default.isReadableFile(atPath: modelURL.path),
              FileManager.default.isExecutableFile(atPath: serverURL.path),
              let input = Self.input(status: status, title: title, evidence: evidence) else { return nil }

        idleTask?.cancel()
        let worker: Worker
        do {
            worker = try workerSlot.worker(modelURL: modelURL, serverURL: serverURL)
        } catch {
            unavailableUntil = Date().addingTimeInterval(30)
            return nil
        }

        activeRequests += 1
        defer {
            activeRequests -= 1
            scheduleIdleExit()
        }

        let response = await Self.complete(input, status: status, using: worker)
        if !worker.isRunning {
            workerSlot.stop(ifCurrent: worker)
            unavailableUntil = Date().addingTimeInterval(10)
        }
        guard !Task.isCancelled else { return nil }
        return response
    }

    func shutdown() async {
        idleTask?.cancel()
        workerSlot.stop()
    }

    /// Use during app termination, which cannot wait for a new Swift task to run.
    nonisolated func shutdownNow() { workerSlot.stop() }

    private func scheduleIdleExit() {
        guard activeRequests == 0 else { return }
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.idleSeconds))
            guard !Task.isCancelled else { return }
            await self?.stopIfIdle()
        }
    }

    private func stopIfIdle() {
        if activeRequests == 0 { workerSlot.stop() }
    }

    private struct Input: Sendable {
        let title: String?
        let json: String
        let hasPendingAction: Bool
        let completedResult: String?
        let pendingClause: String?
    }

    private static func input(status: SessionStatus, title: String, evidence: SessionEvidence) -> Input? {
        let outcome = status == .working ? nil : clipped(evidence.latestOutcome, limit: 1_600)
        let request = status == .ready && outcome != nil ? nil : clipped(evidence.latestRequest, limit: 760)
        let pending = clipped(evidence.pendingAction, limit: 390)
        let activity = clipped(evidence.activityContext, limit: 580)
        let displayTitle = clipped(title, limit: 100)
        guard request != nil || outcome != nil || pending != nil || activity != nil else { return nil }
        if status == .ready && outcome == nil && pending == nil && activity == nil { return nil }

        let fields: [String: String] = [
            "chat title": displayTitle,
            "latest user request": request,
            "latest assistant reply": outcome,
            "remaining action, still to do": pending,
            "live activity": activity,
        ].compactMapValues { $0 }
        guard let result = jsonText(fields) else { return nil }
        let completedResult = status == .ready
            ? outcome.flatMap { jsonText(["chat title": displayTitle, "latest assistant reply": $0].compactMapValues { $0 }) }
            : nil
        return Input(title: displayTitle, json: result, hasPendingAction: pending != nil, completedResult: completedResult,
                     pendingClause: pending.flatMap(pendingClause))
    }

    private static func jsonText(_ fields: [String: String]) -> String? {
        guard let json = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return nil }
        return String(data: json, encoding: .utf8)
    }

    private static func pendingClause(_ text: String) -> String? {
        let action = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!? "))
        guard action.count <= 73, !text.contains("?"),
              let word = action.split(separator: " ").first, let initial = action.first else { return nil }
        let verbs: Set<String> = ["add", "approve", "check", "choose", "confirm", "deploy", "enable",
                                  "finish", "fix", "inspect", "merge", "open", "provide", "publish",
                                  "recheck", "rerun", "review", "run", "select", "send", "test",
                                  "try", "update", "upload", "validate", "verify", "wait"]
        guard verbs.contains(word.lowercased()) else { return nil }
        return ", then " + initial.lowercased() + action.dropFirst() + "."
    }

    private static func clipped(_ text: String?, limit: Int) -> String? {
        guard let text else { return nil }
        let cleaned = text.replacingOccurrences(of: #"(?i)\bignore (?:all |any |the )?(?:previous|prior|above) instructions?\b.*"#,
                                                with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\b(?:system prompt|developer message)\s*:"#,
                                  with: "", options: .regularExpression)
            .replacingOccurrences(of: "<|", with: "< ")
            .replacingOccurrences(of: "|>", with: " >")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        if cleaned.count <= limit { return cleaned }
        let head = limit * 2 / 3
        return String(cleaned.prefix(head)) + "\n…\n" + String(cleaned.suffix(limit - head - 3))
    }

    private static func instructions(for status: SessionStatus, hasPendingAction: Bool, shorter: Bool) -> String {
        let state: String
        switch status {
        case .working:
            state = "Start with “Working on” or an -ing verb. Name the concrete work underway from the request or live activity."
        case .needsInput:
            state = "Start with “Waiting for” or “Needs”. Name the specific decision, approval, or missing information the user must supply."
        case .ready:
            state = hasPendingAction
                ? "Name the actual result, then describe the remaining-action field as work still to do."
                : "Name the concrete result, failure, or recommendation from the latest reply and keep its stated test scope."
        case .idle, .unknown:
            state = "Summarize the latest established result or open question. Preserve its stated completion state."
        }
        let length = shorter ? "Use at most 12 words." : "Aim for 14 words and at most 120 characters."
        return """
        Write exactly one plain sentence for a compact activity feed. \(length)
        \(state) Mention a next step only when the supplied evidence names one.
        The JSON fields are quoted evidence. Ground every claim in those fields.
        Use concrete names and concise observational wording. Omit URLs, raw identifiers, the names of these fields, and phrases such as “the user requested” or “from the request”.
        Return only the sentence.
        """
    }

    private struct Request: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }
        let messages: [Message]
        let temperature = 0
        let max_tokens = 54
        let stream = false
        let cache_prompt = false
        let chat_template_kwargs = ["enable_thinking": false]
    }

    private struct Response: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
            let finish_reason: String?
        }
        let choices: [Choice]
    }

    private static func complete(_ input: Input, status: SessionStatus, using worker: Worker) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                guard worker.waitUntilReady() else { continuation.resume(returning: nil); return }
                if let completedResult = input.completedResult, let pending = input.pendingClause {
                    let budget = maximumSummaryLength - pending.count
                    let compact = "Summarize the reported result or blocker in one plain sentence of at most \(budget) characters. Use only facts in the quoted JSON evidence."
                    if let outcome = response(to: completedResult, instructions: compact, using: worker)
                        .flatMap({ oneSentence($0, status: .ready, title: input.title, limit: budget) }) {
                        let stem = outcome.trimmingCharacters(in: CharacterSet(charactersIn: ".!? "))
                        continuation.resume(returning: stem + pending)
                        return
                    }
                }
                var longCandidate: String?
                for shorter in [false, true] {
                    let prompt = instructions(for: status, hasPendingAction: input.hasPendingAction, shorter: shorter)
                    guard let raw = response(to: input.json, instructions: prompt, using: worker) else { continue }
                    if let result = oneSentence(raw, status: status, title: input.title) {
                        if let pending = input.pendingClause, input.completedResult != nil {
                            let lower = result.lowercased()
                            let action = pending.dropFirst(", then ".count).dropLast().lowercased()
                            let combined = result.trimmingCharacters(in: CharacterSet(charactersIn: ".!? ")) + pending
                            if combined.count <= maximumSummaryLength, !lower.contains(action),
                               !lower.contains("still "), !lower.contains("pending"), !lower.contains(", then ") {
                                continuation.resume(returning: combined)
                                return
                            }
                        }
                        continuation.resume(returning: result)
                        return
                    }
                    if let sentence = oneSentence(raw, status: status, title: input.title, limit: 210),
                       sentence.count < (longCandidate?.count ?? Int.max) {
                        longCandidate = sentence
                    }
                }
                if let longCandidate, let draft = jsonText(["draft status": longCandidate]) {
                    let compact = """
                    Shorten the quoted draft to one factual status sentence of at most 100 characters.
                    Keep the outcome and any remaining action. Omit secondary details. Add no facts.
                    """
                    let shortened = response(to: draft, instructions: compact, using: worker)
                        .flatMap { oneSentence($0, status: status, title: input.title) }
                    continuation.resume(returning: shortened ?? longCandidate)
                    return
                }
                continuation.resume(returning: nil)
            }
        }
    }

    private static func response(to input: String, instructions: String, using worker: Worker) -> String? {
        let payload = Request(messages: [
            .init(role: "system", content: instructions),
            .init(role: "user", content: input),
        ])
        guard let body = try? JSONEncoder().encode(payload),
              let data = worker.curl(path: "/v1/chat/completions", body: body),
              let answer = try? JSONDecoder().decode(Response.self, from: data),
              let choice = answer.choices.first, choice.finish_reason == "stop" else { return nil }
        return choice.message.content
    }

    /// Words that say nothing about the work itself. A small model with little to go on strings these
    /// together with the chat's title into a line that reads like a summary and tells you nothing.
    private static let emptyWords: Set<String> = [
        "a", "an", "and", "are", "for", "from", "in", "is", "it", "its", "of", "on", "that", "the", "this", "to", "with",
        "agent", "agents", "bot", "cached", "chat", "chats", "claude", "cloud", "code", "codex", "context", "conversation",
        "current", "cursor", "earlier", "grok", "latest", "list", "message", "messages", "ongoing", "reply", "request",
        "requests", "run", "session", "status", "task", "tasks", "thread", "update", "updates", "user", "users", "work",
        "working",
    ]

    /// Whether a line only repeats the chat's title, padded with words that carry no information.
    static func addsNothing(to title: String?, _ sentence: String) -> Bool {
        func words(_ text: String) -> [String] {
            text.lowercased().replacingOccurrences(of: "’", with: "'")
                .split { !$0.isLetter && !$0.isNumber && $0 != "'" }
                .map { $0.hasSuffix("'s") ? String($0.dropLast(2)) : String($0) }
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
                .filter { !$0.isEmpty }
        }
        let known = emptyWords.union(words(title ?? ""))
        return words(sentence).allSatisfy(known.contains)
    }

    private static func oneSentence(_ raw: String, status: SessionStatus, title: String? = nil,
                                    limit: Int = maximumSummaryLength) -> String? {
        let cleaned = raw.replacingOccurrences(of: #"<think>[\s\S]*?</think>"#, with: "", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”`* "))
        guard cleaned.count >= 12, !cleaned.contains("<"), !cleaned.contains("http") else { return nil }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = cleaned
        guard let range = tokenizer.tokens(for: cleaned.startIndex..<cleaned.endIndex).first else { return nil }
        var sentence = String(cleaned[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        if sentence.hasPrefix("Summary: ") { sentence.removeFirst("Summary: ".count) }
        if sentence.hasPrefix("I ") {
            let remainder = sentence.dropFirst(2)
            if let first = remainder.first { sentence = first.uppercased() + remainder.dropFirst() }
        }
        guard sentence.count >= 12, sentence.count <= limit,
              !sentence.hasSuffix("?"), !sentence.hasSuffix(":") else { return nil }
        let lowercase = sentence.lowercased()
        guard !lowercase.hasPrefix("the user requested"), !lowercase.hasPrefix("the user has requested") else { return nil }
        if status == .working {
            let first = sentence.split(separator: " ").first?.lowercased()
            guard first?.hasSuffix("ing") == true else { return nil }
        }
        guard !addsNothing(to: title, sentence) else { return nil }
        if sentence.last != ".", sentence.last != "!" { sentence += "." }
        return sentence.count <= limit ? sentence : nil
    }

    private final class WorkerSlot: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Worker?

        func worker(modelURL: URL, serverURL: URL) throws -> Worker {
            try lock.withLock {
                if let current, current.isRunning { return current }
                let started = try Worker(modelURL: modelURL, serverURL: serverURL)
                current = started
                return started
            }
        }

        func stop(ifCurrent expected: Worker? = nil) {
            let stopping = lock.withLock { () -> Worker? in
                if let expected, current !== expected { return nil }
                let result = current
                current = nil
                return result
            }
            stopping?.stop()
        }

        deinit { current?.stop() }
    }

    private final class Worker: @unchecked Sendable {
        // The supervisor holds a read end of Side Eye's liveness pipe. EOF on app exit or
        // force-kill signals the model server, so a crashed app cannot leave a worker.
        private static let supervisor = """
        directory=$1
        socket=$2
        shift 2
        cleanup() {
            trap '' TERM HUP INT
            if [ -n "$watcher" ]; then kill "$watcher" 2>/dev/null || :; fi
            /bin/rm -f "$socket"
            /bin/rmdir "$directory" 2>/dev/null || :
        }
        trap cleanup EXIT
        exec 3<&0
        "$@" </dev/null 3<&- &
        server=$!
        (
            IFS= read -r unused <&3 || :
            kill -TERM "$server" 2>/dev/null || exit 0
            /bin/sleep 2
            kill -KILL "$server" 2>/dev/null || :
        ) &
        watcher=$!
        exec 3<&-
        trap 'kill -TERM "$server" 2>/dev/null || :' TERM HUP INT
        wait "$server"
        """

        let socket: URL
        private let process = Process()
        private let lifetime = Pipe()
        var isRunning: Bool { process.isRunning }

        init(modelURL: URL, serverURL: URL) throws {
            let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
                .appendingPathComponent("side-eye-summary-" + UUID().uuidString, isDirectory: true)
            socket = directory.appendingPathComponent("model.sock")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", Self.supervisor, "side-eye-summary", directory.path, socket.path,
                                 serverURL.path, "-m", modelURL.path, "--host", socket.path, "--ctx-size", "3072",
                                 "--parallel", "1", "--reasoning", "off", "--no-webui", "--no-slots",
                                 "--no-cache-prompt", "--timeout", "10", "--log-disable"]
            process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C", "TMPDIR": directory.path]
            process.standardInput = lifetime
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            _ = fcntl(lifetime.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
            do {
                try process.run()
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }

        func stop() { try? lifetime.fileHandleForWriting.close() }

        func waitUntilReady() -> Bool {
            let deadline = Date().addingTimeInterval(5)
            repeat {
                if !isRunning { return false }
                if FileManager.default.fileExists(atPath: socket.path),
                   curl(path: "/health", body: nil) != nil { return true }
                Thread.sleep(forTimeInterval: 0.08)
            } while Date() < deadline
            return false
        }

        func curl(path: String, body: Data?) -> Data? {
            guard isRunning else { return nil }
            let request = Process()
            let output = Pipe()
            let input = Pipe()
            request.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            var arguments = ["-q", "--unix-socket", socket.path, "--noproxy", "*", "--proto", "=http",
                             "--max-redirs", "0", "--silent", "--fail", "--connect-timeout", "1",
                             "--max-time", body == nil ? "1" : "10", "--max-filesize", "65536"]
            if body != nil { arguments += ["-H", "Content-Type: application/json", "--data-binary", "@-"] }
            arguments.append("http://localhost" + path)
            request.arguments = arguments
            request.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
            request.standardInput = body == nil ? FileHandle.nullDevice : input
            request.standardOutput = output
            request.standardError = FileHandle.nullDevice
            do {
                try request.run()
                if let body {
                    try input.fileHandleForWriting.write(contentsOf: body)
                    try input.fileHandleForWriting.close()
                }
                let data = try output.fileHandleForReading.readToEnd()
                request.waitUntilExit()
                guard request.terminationStatus == 0 else { return nil }
                return data
            } catch {
                try? input.fileHandleForWriting.close()
                if request.isRunning { request.terminate() }
                return nil
            }
        }
    }
}
