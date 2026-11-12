import AppKit

@MainActor
enum RouteOpener {
    static func open(_ route: Route) -> Bool {
        switch route {
        case .url(let raw):
            guard let url = URL(string: raw) else { return false }
            return NSWorkspace.shared.open(url)
        case .claude(let sessionID, let directory, let tty):
            return ClaudeProvider.jump(sessionID: sessionID, directory: directory, tty: tty)
        case .claudeBackground(let id, let directory):
            return ClaudeProvider.jumpBackground(id: id, directory: directory)
        }
    }
}
