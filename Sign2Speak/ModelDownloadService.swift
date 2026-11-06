import Foundation

enum ModelDownloadState: Equatable {
    case idle, checking, downloading(receivedBytes: Int64), verifying, failed(String)
    var isActive: Bool {
        switch self { case .checking, .downloading, .verifying: return true; default: return false }
    }
}

enum ModelDownloadEvent: Sendable {
    case progress(taskID: Int, receivedBytes: Int64)
    case completed(taskID: Int, file: URL)
    case failed(taskID: Int, message: String)
}

enum ModelDownloadRecovery: Sendable {
    case none, transferring(taskID: Int, receivedBytes: Int64), completed(URL)
}

@MainActor
protocol ModelDownloading: AnyObject {
    var onEvent: (@MainActor @Sendable (ModelDownloadEvent) -> Void)? { get set }
    func restore() async -> ModelDownloadRecovery
    func start() throws -> Int
    func cancel(taskID: Int)
}

// The system owns the transfer; only a small progress summary reaches SwiftUI.
// Completed files are moved out of URLSession's temporary directory synchronously
// in its delegate, so verification can survive suspension/relaunch.
@MainActor
final class BackgroundModelDownloader: ModelDownloading {
    static var sessionIdentifier: String {
        (Bundle.main.bundleIdentifier ?? "Sign2Speak") + ".sentence-model-download-v1"
    }
    var onEvent: (@MainActor @Sendable (ModelDownloadEvent) -> Void)?
    private let directory: URL
    private let manifest: ModelManifest
    private let delegate: ModelDownloadDelegate
    private var cancelledTaskIDs: Set<Int> = []
    private lazy var session: URLSession = {
        #if os(iOS)
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        #else
        let config = URLSessionConfiguration.default
        #endif
        config.allowsCellularAccess = true
        config.httpMaximumConnectionsPerHost = 1
        config.timeoutIntervalForResource = 7 * 24 * 60 * 60
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()

    init(directory: URL, manifest: ModelManifest) {
        self.directory = directory
        self.manifest = manifest
        delegate = ModelDownloadDelegate(directory: directory, manifest: manifest)
        delegate.deliver = { [weak self] event in
            Task { @MainActor in self?.onEvent?(event) }
        }
    }

    func restore() async -> ModelDownloadRecovery {
        let tasks = await session.allTasks
        let owned = tasks.compactMap { $0 as? URLSessionDownloadTask }.filter {
            $0.taskDescription == manifest.sha256 && !cancelledTaskIDs.contains($0.taskIdentifier)
                && ($0.state == .running || $0.state == .suspended)
        }
        // A completed delegate file takes precedence over a surviving task.
        if let file = Self.completedFiles(in: directory).first {
            owned.forEach { $0.cancel() }
            return .completed(file)
        }
        if let task = owned.first {
            owned.dropFirst().forEach { $0.cancel() }
            task.resume()
            return .transferring(taskID: task.taskIdentifier, receivedBytes: task.countOfBytesReceived)
        }
        return .none
    }

    func start() throws -> Int {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        let task = session.downloadTask(with: manifest.downloadURL)
        task.taskDescription = manifest.sha256
        task.resume()
        return task.taskIdentifier
    }

    func cancel(taskID: Int) {
        cancelledTaskIDs.insert(taskID)
        Task {
            let tasks = await session.allTasks
            tasks.filter { $0.taskIdentifier == taskID }.forEach { $0.cancel() }
        }
    }

    private static func completedFiles(in directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "modeldownload" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
    }
}

// No UI/controller objects or model bytes are retained by the delegate.
private final class ModelDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let directory: URL
    let manifest: ModelManifest
    // Assigned once, before the URLSession is created; callbacks use its serial delegate queue.
    var deliver: (@Sendable (ModelDownloadEvent) -> Void)?
    private var lastProgress: [Int: Double] = [:]

    init(directory: URL, manifest: ModelManifest) { self.directory = directory; self.manifest = manifest }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard downloadTask.taskDescription == manifest.sha256 else { return }
        if totalBytesWritten > manifest.bytes {
            downloadTask.cancel()
            deliver?(.failed(taskID: downloadTask.taskIdentifier, message: "The download is larger than expected. Please retry."))
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let id = downloadTask.taskIdentifier
        guard now - (lastProgress[id] ?? -1) >= 0.2 else { return }
        lastProgress[id] = now
        deliver?(.progress(taskID: id, receivedBytes: totalBytesWritten))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard downloadTask.taskDescription == manifest.sha256 else { return }
        let id = downloadTask.taskIdentifier
        lastProgress[id] = nil
        do {
            guard let response = downloadTask.response as? HTTPURLResponse,
                  response.statusCode == 200 || response.statusCode == 206 else {
                throw AppError.invalidModel("The model server could not complete the download. Please retry.")
            }
            guard try location.resourceValues(forKeys: [.fileSizeKey]).fileSize == Int(manifest.bytes) else {
                throw AppError.invalidModel("The download is incomplete. Please retry.")
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let durable = directory.appendingPathComponent(UUID().uuidString + ".modeldownload")
            try FileManager.default.moveItem(at: location, to: durable)
            deliver?(.completed(taskID: id, file: durable))
        } catch {
            deliver?(.failed(taskID: id, message: (error as? LocalizedError)?.errorDescription ?? "The download could not be saved. Check available storage and retry."))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lastProgress[task.taskIdentifier] = nil
        guard task.taskDescription == manifest.sha256, let error else { return }
        let code = (error as NSError).code
        let message = code == NSURLErrorCancelled ? "Download cancelled. You can try again."
            : "Download interrupted. Check your connection and available storage, then retry."
        deliver?(.failed(taskID: task.taskIdentifier, message: message))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in ModelDownloadBackgroundEvents.finish() }
    }
}

@MainActor
enum ModelDownloadBackgroundEvents {
    private static var completion: (() -> Void)?
    static func register(_ handler: @escaping () -> Void) {
        completion = handler
    }
    static func finish() {
        guard let handler = completion else { return }
        completion = nil
        handler()
    }
}
