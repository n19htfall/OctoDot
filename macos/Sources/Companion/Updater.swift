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
    private var installTask: Task<Void, Never>?
    var canStopInstallWait: Bool { installTask != nil }
    @ObservationIgnored private var downloadID: UUID?
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
        guard automatic, !UpdateNotice.shared.isVisible else { return }
        switch phase {
        case .failed:
            break // Retry on the next timer tick, even after a recent successful check.
        case .idle, .upToDate:
            let last = UserDefaults.standard.double(forKey: "lastUpdateCheck")
            guard Date().timeIntervalSince1970 - last >= 86_400 else { return }
        case .checking, .available, .downloading, .verifying, .installing:
            return
        }
        Task { await check() }
    }

    /// `interactive` is a click on "检查更新…": the update window opens and
    /// shows the outcome. The daily check leaves it closed.
    func check(interactive: Bool = false) async {
        if phase == .checking || phase == .downloading || phase == .verifying || phase == .installing {
            if interactive { UpdateNotice.shared.present(self) }
            return
        }
        phase = .checking
        if interactive { UpdateNotice.shared.present(self) }
        if let outcome = await InstallerClient.shared.pendingUpdate() {
            if outcome.ok {
                phase = .installing
                relaunch()
            } else {
                phase = .failed(outcome.message)
            }
            return
        }
        guard let key = Self.publicKey,
              let verifier = try? UpdateVerifier(publicKeyBase64: key, releasesPrefix: Identity.releasesPrefix),
              let url = URL(string: Identity.appcastURL) else {
            phase = .failed("这个 OctoDot 构建没有更新密钥，无法检查更新。")
            return
        }
        let configuration: URLSessionConfiguration
        do { configuration = try UpdateProxyConfiguration.ephemeral() } catch {
            phase = .failed("\(error)")
            return
        }
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(from: url)
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
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
        } catch {
            phase = .failed("\(error)")
        }
    }

    func startInstall() {
        guard installTask == nil else { return }
        installTask = Task { [weak self] in
            guard let self else { return }
            defer { self.installTask = nil }
            await self.install()
        }
    }

    func stopInstallWait() {
        installTask?.cancel()
    }

    /// Downloads, checks and installs the update, then starts the new app.
    private func install() async {
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
        let id = UUID()
        downloadID = id
        defer { downloadID = nil }
        phase = .downloading
        do {
            let file = try await ProgressDownload.fetch(url, configuration: configuration) { [weak self] bytes, _ in
                Task { @MainActor in
                    if let self, self.downloadID == id { self.note(bytes) }
                }
            }
            defer { try? FileManager.default.removeItem(at: file) }
            try Task.checkCancellation()
            note(downloadSize)
            phase = .verifying
            let verification = Task.detached {
                try verifier.verifyPayload(at: file, for: manifest)
            }
            try await withTaskCancellationHandler {
                try await verification.value
            } onCancel: {
                verification.cancel()
            }
            try Task.checkCancellation()
            let handle = try FileHandle(forReadingFrom: file)
            phase = .installing
            let (ok, message) = await InstallerClient.shared.installUpdate(manifest: manifestData, file: handle)
            try? handle.close()
            guard ok else {
                phase = Task.isCancelled && message == Outcome.cancelled.message ? .available(manifest) : .failed(message)
                return
            }
            relaunch()
        } catch is CancellationError {
            phase = .available(manifest)
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
