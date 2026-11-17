import Foundation

/// Schedules bounded local reads and generation without delaying discovery or UI updates.
final class SessionSummaryProvider: @unchecked Sendable {
    static let preferenceKey = "useLocalModelForNextSteps"

    private struct Key: Hashable, Sendable {
        let id: String
        let activity: String
        let status: SessionStatus
        let includeTranscript: Bool
    }

    private struct Work: Sendable {
        let key: Key
        let session: Session
    }

    private struct Cached {
        var text: String?
        let evidenceHash: Int
        let generated: Bool
        var refreshAfter: Date
    }

    private let defaults: UserDefaults
    private let reader = SessionEvidenceReader(home: FileManager.default.homeDirectoryForCurrentUser,
                                               codexHome: CodexProvider.defaultHome)
    private let engine = LocalSummaryEngine()
    private let lock = NSLock()
    private var activeKeys = Set<Key>()
    private var cache: [Key: Cached] = [:]
    private var pending: [Work] = []
    private var inFlight: Key?
    private var workerRunning = false
    private var stopped = false
    private var updateHandler: (@Sendable () -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func observeUpdates(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { updateHandler = handler }
    }

    private var transcriptEnabled: Bool {
        defaults.bool(forKey: Self.preferenceKey) && LocalSummaryEngine.isInstalled
    }

    func annotate(_ sessions: [Session]) -> [Session] {
        let includeTranscript = transcriptEnabled
        let grokMainOnly = defaults.bool(forKey: "grokMainAgentsOnly")
        let mainGrokIDs = Set(defaults.stringArray(forKey: "grokMainAgentIDs") ?? [])
        let now = Date()
        let (annotated, startWorker) = lock.withLock {
            let work = sessions.compactMap { session -> Work? in
                guard session.detail != "Pinned link", session.status != .unknown else {
                    return nil
                }
                if session.source == .grok, grokMainOnly, !mainGrokIDs.contains(session.id) { return nil }
                let key = Self.key(for: session, includeTranscript: includeTranscript)
                return Work(key: key, session: session)
            }
            activeKeys = Set(work.map(\.key))
            cache = cache.filter { activeKeys.contains($0.key) }
            pending = stopped ? [] : work.filter {
                $0.key != inFlight && (cache[$0.key]?.refreshAfter ?? .distantPast) <= now
            }.sorted {
                let lhs = Self.priority($0.session.status)
                let rhs = Self.priority($1.session.status)
                if lhs != rhs { return lhs < rhs }
                return $0.session.updatedAt > $1.session.updatedAt
            }

            let annotated = applyingCache(to: sessions, includeTranscript: includeTranscript)
            let startWorker = !pending.isEmpty && !workerRunning
            if startWorker { workerRunning = true }
            return (annotated, startWorker)
        }
        if startWorker {
            Task.detached(priority: .utility) { [weak self] in await self?.run() }
        }
        return annotated
    }

    func cachedSummaries(for sessions: [Session]) -> [Session] {
        let includeTranscript = transcriptEnabled
        return lock.withLock { applyingCache(to: sessions, includeTranscript: includeTranscript) }
    }

    private func applyingCache(to sessions: [Session], includeTranscript: Bool) -> [Session] {
        sessions.map { session in
            var annotated = session
            annotated.stateSummary = cache[Self.key(for: session, includeTranscript: includeTranscript)]?.text
            return annotated
        }
    }

    private static func key(for session: Session, includeTranscript: Bool) -> Key {
        Key(id: session.id, activity: session.activityID ?? String(session.updatedAt.timeIntervalSince1970),
            status: session.status, includeTranscript: includeTranscript)
    }

    func generatedCount(in sessions: [Session]) -> Int {
        let ids = Set(sessions.map(\.id))
        return lock.withLock { cache.filter { ids.contains($0.key.id) && $0.value.generated }.count }
    }

    func shutdown() async {
        lock.withLock {
            stopped = true
            activeKeys.removeAll()
            pending.removeAll()
            cache.removeAll()
            updateHandler = nil
        }
        await engine.shutdown()
    }

    private func run() async {
        while let work = dequeue() {
            await resolve(work)
            lock.withLock { inFlight = nil }
        }
    }

    private func dequeue() -> Work? {
        lock.withLock {
            guard !stopped, !pending.isEmpty else {
                workerRunning = false
                return nil
            }
            let work = pending.removeFirst()
            inFlight = work.key
            return work
        }
    }

    private func resolve(_ work: Work) async {
        let mayReadTranscript = work.key.includeTranscript && defaults.bool(forKey: Self.preferenceKey)
        let evidence = reader.read(work.session, includeTranscript: mayReadTranscript)
        let fingerprint = Self.fingerprint(of: evidence)
        let previous = lock.withLock { cache[work.key] }
        let retry: TimeInterval = work.session.status == .working || work.session.status == .needsInput ? 12 : 30

        if var previous, previous.evidenceHash == fingerprint,
           previous.generated || !mayReadTranscript {
            previous.refreshAfter = Date().addingTimeInterval(retry)
            save(previous, for: work.key)
            return
        }

        let hasEvidence = evidence.latestRequest != nil || evidence.latestOutcome != nil ||
            evidence.pendingAction != nil || evidence.activityContext != nil
        let fallback = Self.fallback(for: work.session, evidence: evidence)
        guard hasEvidence else {
            save(Cached(text: previous?.text ?? fallback, evidenceHash: fingerprint, generated: previous?.generated ?? false,
                        refreshAfter: Date().addingTimeInterval(retry)), for: work.key)
            return
        }

        if let fallback, previous?.text == nil {
            save(Cached(text: fallback, evidenceHash: fingerprint, generated: false,
                        refreshAfter: Date().addingTimeInterval(retry)), for: work.key)
        }
        let active = lock.withLock { activeKeys.contains(work.key) && !stopped }
        let summary = mayReadTranscript && active
            ? await engine.summarize(status: work.session.status, title: work.session.title, evidence: evidence)
            : nil
        save(Cached(text: summary ?? fallback,
                    evidenceHash: fingerprint, generated: summary != nil,
                    refreshAfter: Date().addingTimeInterval(retry)), for: work.key)
    }

    private func save(_ value: Cached, for key: Key) {
        let handler: (@Sendable () -> Void)? = lock.withLock {
            guard activeKeys.contains(key), !stopped else { return nil }
            let changed = cache[key]?.text != value.text
            cache[key] = value
            return changed ? updateHandler : nil
        }
        handler?()
    }

    private static func fingerprint(of evidence: SessionEvidence) -> Int {
        var hasher = Hasher()
        hasher.combine(evidence.latestRequest)
        hasher.combine(evidence.latestOutcome)
        hasher.combine(evidence.pendingAction)
        hasher.combine(evidence.activityContext)
        return hasher.finalize()
    }

    private static func priority(_ status: SessionStatus) -> Int {
        switch status {
        case .needsInput: 0
        case .ready: 1
        case .working: 2
        case .idle: 3
        case .unknown: 4
        }
    }

    private static func fallback(for session: Session, evidence: SessionEvidence) -> String? {
        if let action = sentence(evidence.pendingAction) { return action }
        if let activity = sentence(evidence.activityContext) { return activity }
        switch session.status {
        case .working:
            if let request = sentence(evidence.latestRequest), request.count <= 95 {
                return "Working on the request “" + request.trimmingCharacters(in: CharacterSet(charactersIn: ".!?")) + "”."
            }
            let topic = String(session.title.prefix(72)) + (session.title.count > 72 ? "…" : "")
            return session.source.name + " is working on “" + topic + "”."
        case .ready:
            return "Open the chat to review its latest update."
        case .needsInput:
            return "Open the chat to respond to its pending request."
        case .idle, .unknown:
            return nil
        }
    }

    private static func sentence(_ input: String?) -> String? {
        guard let input else { return nil }
        let text = input.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty, text.count <= 145 else { return nil }
        return text.hasSuffix(".") || text.hasSuffix("?") || text.hasSuffix("!") ? text : text + "."
    }
}
