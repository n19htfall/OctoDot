import CryptoKit
import Foundation

/// The grammar model in the folder shared with the input method (GrammarPin;
/// docs/distribution-and-onboarding.md, section 5). The disk image's
/// OctoDot.app carries a copy (Contents/Resources/Grammar), which an install
/// puts there; an update's OctoDot.app carries none, so an update brings the
/// 400 MB only when data/grammar.lock changed, downloaded then from a release
/// of its own. Either way the model goes in only with the SHA-256 that the
/// input method's signed bundle pins, and through a staging folder renamed
/// into place, so the input method never maps half a file.
enum GrammarStore {
    enum Failure: Error, CustomStringConvertible {
        case noPin, noSharedFolder, wrongSize, wrongHash, http(Int)

        var description: String {
            switch self {
            case .noPin: "随附的输入法没有指定语法模型"
            case .noSharedFolder: "与输入法共享的文件夹不存在"
            case .wrongSize, .wrongHash: "文件不是输入法所需要的模型"
            case .http(let status): "服务器返回 \(status)"
            }
        }
    }

    /// The model the input method inside this app wants.
    static var pin: GrammarPin? {
        GrammarPin(ime: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/OctoDotIME.app"))
    }

    /// This app's own copy of it: the disk image's app has one, an update's none.
    static func bundledCopy(of pin: GrammarPin) -> URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Grammar/\(pin.name)"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Whether the shared folder lacks the model the input method wants.
    static var isMissing: Bool { pin.map { !$0.isInstalled } ?? false }

    /// Puts the model in the shared folder unless it is there: copied from
    /// this app (a clone, on APFS), else downloaded, `progress` getting the
    /// share downloaded. True if it put one there.
    @discardableResult
    static func ensure(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Bool {
        guard let pin else { throw Failure.noPin }
        guard !pin.isInstalled else { return false }
        guard let root = GrammarPin.root, let folder = pin.folder else { throw Failure.noSharedFolder }
        let fm = FileManager.default
        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let staged = staging.appendingPathComponent(pin.name)
        if let copy = bundledCopy(of: pin) {
            try await Task.detached { try FileManager.default.copyItem(at: copy, to: staged) }.value
        } else {
            guard let url = pin.url else { throw Failure.noPin }
            let file = try await Download.run(url, expected: pin.size, progress: progress)
            do { try fm.moveItem(at: file, to: staged) } catch {
                try? fm.removeItem(at: file)
                throw error
            }
        }
        let size = (try? fm.attributesOfItem(atPath: staged.path)[.size] as? NSNumber)?.uint64Value
        guard size == pin.size else { throw Failure.wrongSize }
        guard try await Task.detached(operation: { try sha256(of: staged) }).value == pin.sha256 else {
            throw Failure.wrongHash
        }
        try? fm.removeItem(at: folder)                  // what an interrupted attempt left
        try fm.moveItem(at: staging, to: folder)
        return true
    }

    /// Removes every model but the one the installed input method wants, and
    /// whatever an interrupted attempt left. After an install, never before:
    /// until then the input method in use may want another.
    static func prune() {
        guard let pin, let root = GrammarPin.root,
              let items = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        else { return }
        for item in items where item.lastPathComponent != pin.sha256 { try? FileManager.default.removeItem(at: item) }
    }

    /// Removes the models (uninstalling: they are not the user's data).
    static func removeAll() {
        if let root = GrammarPin.root { try? FileManager.default.removeItem(at: root) }
    }

    private static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let more = try autoreleasepool { () -> Bool in
                guard let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty else { return false }
                hasher.update(data: chunk)
                return true
            }
            if !more { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// One download that reports its progress (URLSession's async download
/// reports none). The delegate's callbacks come one at a time, on the
/// session's own serial queue.
private final class Download: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let expected: UInt64
    private let progress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var file: URL?
    private var failure: Error?
    private var reported = -1.0

    private init(expected: UInt64, progress: @escaping @Sendable (Double) -> Void) {
        self.expected = expected
        self.progress = progress
    }

    static func run(_ url: URL, expected: UInt64, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let download = Download(expected: expected, progress: progress)
        let session = URLSession(configuration: try UpdateProxyConfiguration.ephemeral(), delegate: download, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            download.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? Double(totalBytesExpectedToWrite) : Double(expected)
        let share = min(1, Double(totalBytesWritten) / max(total, 1))
        if share - reported >= 0.005 || share == 1 {
            reported = share
            progress(share)
        }
    }

    /// The file is deleted when this returns, so it is moved aside first.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, status != 200 {
            failure = GrammarStore.Failure.http(status)
            return
        }
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("grammar-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: kept)
            file = kept
        } catch {
            failure = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let continuation = self.continuation
        self.continuation = nil
        if let error = error ?? failure {
            if let file { try? FileManager.default.removeItem(at: file) }
            continuation?.resume(throwing: error)
        } else if let file {
            continuation?.resume(returning: file)
        } else {
            continuation?.resume(throwing: GrammarStore.Failure.http(0))
        }
    }
}
