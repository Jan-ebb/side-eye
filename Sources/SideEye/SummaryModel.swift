import CryptoKit
import Foundation

/// The summary model as a file: where Side Eye looks for it, where a copy comes from and how a copy is
/// checked. The release download has no model inside, so someone who wants summaries fetches this one
/// file, once, after asking for it.
struct SummaryModel: Sendable {
    var source: URL
    var sha256: String
    var byteCount: Int64
    /// Where a downloaded copy is kept.
    var downloaded: URL
    /// A copy built into this copy of Side Eye, which the packaging script can do.
    var bundled: URL?

    /// The pinned weights named in ModelLicenses/SideEyeSummary.md. The link names one revision, so the
    /// file behind it cannot change.
    static let pinned = SummaryModel(
        source: URL(string: "https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/"
            + "87e547fc268695ff509f27665c7002e98ed078bc/Qwen3.5-2B-Q3_K_M.gguf")!,
        sha256: "8b049f98461020b7e15797e13413fc63b9b500ffa883c74618b618ecbc2bfccf",
        byteCount: 1_107_149_056,
        downloaded: FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Side Eye/Models/SideEyeSummary.gguf"),
        bundled: Bundle.main.url(forResource: "SideEyeSummary", withExtension: "gguf", subdirectory: "Models"))

    /// The model to run: the one built in, else the downloaded one.
    var installed: URL? {
        if let bundled { return bundled }
        return FileManager.default.isReadableFile(atPath: downloaded.path) ? downloaded : nil
    }

    /// A downloaded copy can be deleted again. One built into this copy of Side Eye cannot.
    var isRemovable: Bool { bundled == nil && FileManager.default.fileExists(atPath: downloaded.path) }

    var sizeText: String { Self.sizeText(byteCount) }

    /// "412 MB", "1.1 GB": sizes the way the download is described everywhere.
    static func sizeText(_ bytes: Int64) -> String {
        bytes >= 1_000_000_000 ? String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
                               : "\(bytes / 1_000_000) MB"
    }

    /// True when the file is byte for byte this model. It is read in pieces, never held whole.
    func matches(_ file: URL) -> Bool {
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        guard size.map({ Int64($0) }) == byteCount, let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            let piece = autoreleasepool { try? handle.read(upToCount: 4 << 20) }
            guard let piece, !piece.isEmpty else { break }
            hash.update(data: piece)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined() == sha256.lowercased()
    }
}

/// One download of the model: fetches the file, checks it and only then puts it in place. Events arrive
/// on a background queue. A download that broke off picks up where it stopped when started again.
final class SummaryModelDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    enum Event: Equatable, Sendable {
        case progress(received: Int64, total: Int64)
        case checking
        case finished
        case failed(String)
    }

    private let model: SummaryModel
    private let report: @Sendable (Event) -> Void
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var resumeData: Data?
    private var lastProgress = Date.distantPast

    init(_ model: SummaryModel = .pinned, report: @escaping @Sendable (Event) -> Void) {
        self.model = model
        self.report = report
    }

    func start() {
        let folder = model.downloaded.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            report(.failed("Side Eye couldn’t create the folder for the model."))
            return
        }
        // Room for the file and a little more, so the download cannot fill the disk.
        let free = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        if let free, free < model.byteCount + 200_000_000 {
            report(.failed("Not enough free space. The model needs \(model.sizeText)."))
            return
        }
        // Nothing is kept between launches: no cookies, no cache, no credentials.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = lock.withLock { () -> URLSessionDownloadTask in
            let task = resumeData.map(session.downloadTask(withResumeData:)) ?? session.downloadTask(with: model.source)
            resumeData = nil
            self.session = session
            self.task = task
            return task
        }
        task.resume()
    }

    /// Stops for good. A later start begins from the first byte.
    func cancel() {
        let (session, task) = lock.withLock { () -> (URLSession?, URLSessionDownloadTask?) in
            defer { self.session = nil; self.task = nil; resumeData = nil }
            return (self.session, self.task)
        }
        task?.cancel()
        session?.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let due = lock.withLock { () -> Bool in
            guard Date().timeIntervalSince(lastProgress) >= 0.1 else { return false }
            lastProgress = Date()
            return true
        }
        if due { report(.progress(received: totalBytesWritten, total: model.byteCount)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            report(.failed("The download failed: the server answered with error \(status)."))
            return
        }
        // The system deletes its own copy when this call returns, so the file moves beside its
        // destination first and takes the model's name only once it has passed the check.
        let files = FileManager.default
        let destination = model.downloaded
        let unchecked = destination.appendingPathExtension("download")
        try? files.removeItem(at: unchecked)
        do {
            try files.moveItem(at: location, to: unchecked)
        } catch {
            report(.failed("Side Eye couldn’t save the model."))
            return
        }
        report(.checking)
        guard model.matches(unchecked) else {
            try? files.removeItem(at: unchecked)
            report(.failed("The download was not the expected file, so Side Eye deleted it."))
            return
        }
        do {
            try? files.removeItem(at: destination)
            try files.moveItem(at: unchecked, to: destination)
            report(.finished)
        } catch {
            try? files.removeItem(at: unchecked)
            report(.failed("Side Eye couldn’t save the model."))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        guard let error = error as NSError? else { return }
        guard error.code != NSURLErrorCancelled else { return }
        lock.withLock { resumeData = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data }
        report(.failed("The download stopped: \(error.localizedDescription)"))
    }
}
