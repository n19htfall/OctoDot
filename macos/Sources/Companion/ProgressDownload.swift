import Foundation
import os

/// The delegate keeps the file before URLSession removes it and reports
/// progress on the session's serial delegate queue.
final class ProgressDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    struct HTTPError: Error, CustomStringConvertible {
        let status: Int
        var description: String { "服务器返回 \(status)。" }
    }

    private enum State {
        case preparing, running(URLSessionDownloadTask), cancelled
    }

    private let state = OSAllocatedUnfairLock(initialState: State.preparing)
    private let progress: @Sendable (Int64, Int64) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var downloaded: Result<URL, Error>?
    private var reportedAt = ContinuousClock.now - .seconds(1)

    private init(progress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.progress = progress
    }

    static func fetch(_ url: URL, configuration: URLSessionConfiguration,
                      progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        try Task.checkCancellation()
        let download = ProgressDownload(progress: progress)
        let session = URLSession(configuration: configuration, delegate: download, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let file: URL
        do {
            file = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let task = session.downloadTask(with: url)
                    download.continuation = continuation
                    let start = download.state.withLock { state in
                        guard case .preparing = state else { return false }
                        state = .running(task)
                        return true
                    }
                    if start { task.resume() } else { task.cancel() }
                }
            } onCancel: {
                let task = download.state.withLock { state -> URLSessionDownloadTask? in
                    defer { state = .cancelled }
                    if case .running(let task) = state { return task }
                    return nil
                }
                task?.cancel()
            }
        } catch {
            try Task.checkCancellation()
            throw error
        }
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: file)
            throw CancellationError()
        }
        return file
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let now = ContinuousClock.now
        let complete = totalBytesExpectedToWrite > 0 && totalBytesWritten >= totalBytesExpectedToWrite
        guard complete || now - reportedAt >= .milliseconds(100) else { return }
        reportedAt = now
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, status != 200 {
            downloaded = .failure(HTTPError(status: status))
            return
        }
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("octodot-download-\(UUID().uuidString)")
        downloaded = Result {
            try FileManager.default.moveItem(at: location, to: kept)
            return kept
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let continuation = self.continuation
        self.continuation = nil
        // Release the task held by the delegate once URLSession finishes.
        state.withLock { $0 = .cancelled }
        if let error {
            if case .success(let file) = downloaded { try? FileManager.default.removeItem(at: file) }
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume(with: downloaded ?? .failure(HTTPError(status: 0)))
        }
    }
}
