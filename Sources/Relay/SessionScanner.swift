import Foundation

final class SessionScanner: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Relay.session-scanner", qos: .utility)
    private let codex = CodexProvider()
    private let claude = ClaudeProvider()
    private let desktop = DesktopProvider()
    private let summaries = SessionSummaryProvider()
    private var timer: DispatchSourceTimer?
    private var latestSnapshot: [Session] = []
    private var summaryUpdateQueued = false
    private let receive: @MainActor ([Session]) -> Void
    private let receiveSummaries: @MainActor ([Session]) -> Void

    init(receive: @escaping @MainActor ([Session]) -> Void,
         receiveSummaries: @escaping @MainActor ([Session]) -> Void) {
        self.receive = receive
        self.receiveSummaries = receiveSummaries
        summaries.observeUpdates { [weak self] in self?.queueSummaryUpdate() }
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(4), leeway: .milliseconds(650))
        timer.setEventHandler { [weak self] in self?.scan() }
        self.timer = timer
        timer.resume()
    }

    func refresh() {
        queue.async { [weak self] in self?.scan() }
    }

    func shutdown() async {
        timer?.cancel()
        await summaries.shutdown()
    }

    private func scan() {
        let defaults = UserDefaults.standard
        let includesAutomation = defaults.bool(forKey: SessionStore.automationRunsPreferenceKey)
        let codexSessions: [Session]
        if Source.codex.isEnabled(in: defaults) {
            codexSessions = codex.scan(includeAutomationRuns: includesAutomation)
        } else {
            codex.suspend()
            codexSessions = []
        }
        let claudeSessions = Source.claude.isEnabled(in: defaults) ? claude.scan() : []
        latestSnapshot = codexSessions.filter { includesAutomation || $0.isAutomationRun != true }
            + claudeSessions + desktop.scan()
        let snapshot = summaries.annotate(latestSnapshot)
        DispatchQueue.main.async { [receive] in receive(snapshot) }
    }

    private func queueSummaryUpdate() {
        queue.async { [weak self] in
            guard let self, !self.summaryUpdateQueued else { return }
            self.summaryUpdateQueued = true
            self.queue.asyncAfter(deadline: .now() + .milliseconds(90)) { [weak self] in
                guard let self else { return }
                self.summaryUpdateQueued = false
                let snapshot = self.summaries.cachedSummaries(for: self.latestSnapshot)
                DispatchQueue.main.async { [receiveSummaries = self.receiveSummaries] in
                    receiveSummaries(snapshot)
                }
            }
        }
    }
}
