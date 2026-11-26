import Foundation

/// A release number such as 0.18.6, compared part by part, so that 0.18.10 is newer than 0.18.9.
struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    let parts: [Int]

    /// Reads "0.18.6" or the tag "v0.18.6". Anything else is not a version.
    init?(_ text: String) {
        let pieces = (text.hasPrefix("v") ? text.dropFirst() : Substring(text))
            .split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3 else { return nil }
        var parts: [Int] = []
        for piece in pieces {
            guard !piece.isEmpty, piece.count <= 6, piece.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int(piece) else { return nil }
            parts.append(number)
        }
        self.parts = parts
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        lhs.parts.lexicographicallyPrecedes(rhs.parts)
    }

    var description: String { parts.map(String.init).joined(separator: ".") }

    /// This copy's own version. A development build is a bare program with no version, and is never
    /// offered an update.
    static var current: AppVersion? {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init)
    }
}

/// A newer release than this copy, and how far installing it has come.
struct UpdateOffer: Equatable {
    enum Phase { case ready, installing, failed }

    var version: AppVersion
    var phase = Phase.ready

    /// The sidebar note and Settings say the same thing in the same words.
    var title: String {
        switch phase {
        case .ready: "Side Eye \(version) is available"
        case .installing: "Updating to Side Eye \(version)…"
        case .failed: "Couldn’t update to Side Eye \(version)"
        }
    }

    func detail(current: AppVersion?) -> String {
        switch phase {
        case .ready: current.map { "You have \($0)." } ?? "Newer than this copy."
        case .installing: "Side Eye reopens when it is done."
        case .failed: "Check your connection, then try again."
        }
    }

    /// What the button says. There is none while the update is on its way.
    var actionTitle: String? {
        switch phase {
        case .ready: "Update"
        case .installing: nil
        case .failed: "Try Again"
        }
    }
}

/// The one question Side Eye asks the network without being told to: which release is the newest. The
/// request names no chat, no setting and no person, and is asked at most once a day.
enum UpdateCheck {
    static let newestRelease = URL(string: "https://github.com/Jan-ebb/side-eye/releases/latest")!
    static let interval: TimeInterval = 24 * 60 * 60

    /// GitHub answers that address by sending the caller on to the newest release's own page, whose
    /// address ends in its tag. The installer finds the newest release the same way.
    static func version(fromReleasePage url: URL?) -> AppVersion? {
        guard let url, url.scheme == "https", url.host == "github.com" else { return nil }
        let path = url.pathComponents
        guard path.count >= 2, path[path.count - 2] == "tag" else { return nil }
        return AppVersion(path[path.count - 1])
    }

    /// A clock that was set back must not put the next check off for good.
    static func isDue(last: Date, now: Date) -> Bool {
        last > now || now.timeIntervalSince(last) >= interval
    }

    /// Nil when GitHub can't be reached or answers with something else. Nothing is kept between
    /// checks: no cookies, no cache.
    static func newest() async -> AppVersion? {
        var request = URLRequest(url: newestRelease)
        request.httpMethod = "HEAD"
        request.setValue("Side Eye", forHTTPHeaderField: "User-Agent")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        guard let (_, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return version(fromReleasePage: response.url)
    }
}

/// Installs a release with the installer that came inside this copy: the same script the install
/// command runs. It downloads the release, checks it against its published SHA-256, quits this copy,
/// puts the new one in its place and opens it.
enum UpdateInstaller {
    static var script: URL? { Bundle.main.url(forResource: "install", withExtension: "sh") }

    /// The new copy goes where this one is. A copy that macOS runs from a temporary folder, or whose
    /// folder can't be written to, leaves the choice to the installer.
    static func installFolder(forBundleAt path: String, isWritable: (String) -> Bool) -> String? {
        guard PreferencesModel.canOpenAtLogin(from: path) else { return nil }
        let folder = (path as NSString).deletingLastPathComponent
        return isWritable(folder) ? folder : nil
    }

    /// What the installer is told: the version the note offered and where to put it. It gets none of
    /// this copy's own environment.
    static func environment(version: AppVersion, bundlePath: String, home: String,
                            isWritable: (String) -> Bool) -> [String: String] {
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": home,
                           "SIDE_EYE_VERSION": version.description]
        if let folder = installFolder(forBundleAt: bundlePath, isWritable: isWritable) {
            environment["SIDE_EYE_INSTALL_DIR"] = folder
        }
        return environment
    }

    /// Starts the installer and returns whether it started. `failed` is called only if it stops with
    /// an error; when it succeeds, this copy is no longer running to hear of it.
    static func start(version: AppVersion, failed: @escaping @Sendable () -> Void) -> Bool {
        // The script is handed over as text, so it does not depend on a file inside the copy it replaces.
        guard let script, let text = try? String(contentsOf: script, encoding: .utf8) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", text]
        process.environment = environment(version: version, bundlePath: Bundle.main.bundlePath,
                                          home: NSHomeDirectory(),
                                          isWritable: FileManager.default.isWritableFile(atPath:))
        // It outlives this copy, so it must not write into a pipe that this copy holds.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { if $0.terminationStatus != 0 { failed() } }
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }
}
