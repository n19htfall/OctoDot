import AppKit
import Foundation

/// Software updates (docs/distribution-and-onboarding.md, section 5): the only
/// network use in OctoDot, and only here, in the companion. The manifest is
/// verified (UpdateVerifier) before anything else happens; the download is
/// checked against it; the installer checks both again before it swaps the
/// app; the new companion then brings the input method along.
@MainActor
@Observable
final class Updater {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdateManifest)
        case downloading
        case verifying
        case installing
        case failed(String)
    }

    var phase = Phase.idle
    var downloadedBytes: Int64 = 0
    var downloadSize: Int64 = 0
    /// Average rate since the download started; 0 until a fifth of a second has passed.
    var bytesPerSecond: Int64 = 0
    /// Checks once a day while the companion runs, if the user wants it.
    var automatic: Bool {
        didSet { UserDefaults.standard.set(automatic, forKey: "automaticUpdateChecks") }
    }

    private var manifestData: Data?
    private var timer: Timer?
    private var downloadStarted = Date.distantPast

    /// The key built into this app; nil in a build made without one (then
    /// there are no updates to check).
    static var publicKey: String? {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "OctoDotUpdatePublicKey") as? String, !key.isEmpty
        else { return nil }
        return key
    }

    static var runningBuild: Int { Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0 }

    init() {
        automatic = UserDefaults.standard.bool(forKey: "automaticUpdateChecks")
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
    }

    private func checkIfDue() {
        guard automatic, phase == .idle || phase == .upToDate, !UpdateNotice.shared.isVisible else { return }
        let last = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        if Date().timeIntervalSince1970 - last > 86_400 { Task { await check() } }
    }

    /// `interactive` is a click on "检查更新…": the update window opens and
    /// shows the outcome. The daily check leaves it closed.
    func check(interactive: Bool = false) async {
        if phase == .checking || phase == .downloading || phase == .verifying || phase == .installing {
            if interactive { UpdateNotice.shared.present(self) }
            return
        }
        guard let key = Self.publicKey,
              let verifier = try? UpdateVerifier(publicKeyBase64: key, releasesPrefix: Identity.releasesPrefix),
              let url = URL(string: Identity.appcastURL) else {
            phase = .failed("这个 OctoDot 构建没有更新密钥，无法检查更新。")
            if interactive { UpdateNotice.shared.present(self) }
            return
        }
        let configuration: URLSessionConfiguration
        do { configuration = try UpdateProxyConfiguration.ephemeral() } catch {
            phase = .failed("\(error)")
            if interactive { UpdateNotice.shared.present(self) }
            return
        }
        phase = .checking
        if interactive { UpdateNotice.shared.present(self) }
        let session = URLSession(configuration: configuration)
        do {
            let (data, response) = try await session.data(from: url)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                phase = .failed("更新服务器返回 \((response as? HTTPURLResponse)?.statusCode ?? 0)。")
                return
            }
            do {
                let manifest = try verifier.verify(data, runningBuild: Self.runningBuild)
                manifestData = data
                phase = .available(manifest)
            } catch UpdateError.notNewer {
                phase = .upToDate
            }
        } catch {
            phase = .failed("\(error)")
        }
    }

    /// Downloads, checks and installs the update, then starts the new app.
    func install() async {
        guard case .available(let manifest) = phase, let manifestData, let key = Self.publicKey,
              let verifier = try? UpdateVerifier(publicKeyBase64: key, releasesPrefix: Identity.releasesPrefix),
              let url = URL(string: manifest.url) else { return }
        let configuration: URLSessionConfiguration
        do { configuration = try UpdateProxyConfiguration.ephemeral() } catch {
            phase = .failed("\(error)")
            return
        }
        downloadedBytes = 0
        bytesPerSecond = 0
        downloadSize = Int64(manifest.size)
        downloadStarted = Date()
        phase = .downloading
        do {
            let file = try await UpdateDownload.fetch(url, configuration: configuration) { [weak self] bytes in
                Task { @MainActor in self?.note(bytes) }
            }
            defer { try? FileManager.default.removeItem(at: file) }
            note(downloadSize)
            phase = .verifying
            try await Task.detached {
                try verifier.verifyPayload(at: file, for: manifest)
            }.value
            let handle = try FileHandle(forReadingFrom: file)
            phase = .installing
            let (ok, message) = await InstallerClient.shared.installUpdate(manifest: manifestData, file: handle)
            try? handle.close()
            guard ok else {
                phase = .failed(message)
                return
            }
            relaunch()
        } catch {
            phase = .failed("\(error)")
        }
    }

    private func note(_ bytes: Int64) {
        guard phase == .downloading else { return }
        downloadedBytes = max(downloadedBytes, bytes)
        let elapsed = Date().timeIntervalSince(downloadStarted)
        if elapsed >= 0.2, downloadedBytes > 0 {
            bytesPerSecond = Int64((Double(downloadedBytes) / elapsed).rounded())
        }
    }

    /// The new app is where this one was: start it, and end this one.
    private func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

/// URLSession's async `download(from:)` reports no progress. A resumed download
/// task does: its delegate is called as bytes arrive. The callbacks come one
/// at a time, on the session's own serial queue. The file is deleted when
/// `didFinishDownloadingTo` returns, so it is moved aside first.
private final class UpdateDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let report: @Sendable (Int64) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var file: URL?
    private var failure: Error?
    private var reportedAt = Date.distantPast

    private init(report: @escaping @Sendable (Int64) -> Void) {
        self.report = report
    }

    static func fetch(_ url: URL, configuration: URLSessionConfiguration,
                      report: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        let download = UpdateDownload(report: report)
        let session = URLSession(configuration: configuration, delegate: download, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            download.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let done = totalBytesExpectedToWrite > 0 && totalBytesWritten >= totalBytesExpectedToWrite
        let now = Date()
        guard done || now.timeIntervalSince(reportedAt) >= 0.1 else { return }
        reportedAt = now
        report(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, status != 200 {
            failure = UpdateDownloadError(status: status)
            return
        }
        let kept = FileManager.default.temporaryDirectory
            .appendingPathComponent("octodot-update-\(UUID().uuidString).zip")
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
            continuation?.resume(throwing: UpdateDownloadError(status: 0))
        }
    }
}

private struct UpdateDownloadError: Error, CustomStringConvertible {
    let status: Int
    var description: String { "更新服务器返回 \(status)。" }
}
