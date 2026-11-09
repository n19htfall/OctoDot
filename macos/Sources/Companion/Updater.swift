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
        case installing
        case failed(String)
    }

    var phase = Phase.idle
    /// Checks once a day while the companion runs, if the user wants it.
    var automatic: Bool {
        didSet { UserDefaults.standard.set(automatic, forKey: "automaticUpdateChecks") }
    }

    private var manifestData: Data?
    private var timer: Timer?

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
        guard automatic, phase == .idle || phase == .upToDate else { return }
        let last = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        if Date().timeIntervalSince1970 - last > 86_400 { Task { await check() } }
    }

    func check() async {
        guard let key = Self.publicKey,
              let verifier = try? UpdateVerifier(publicKeyBase64: key, releasesPrefix: Identity.releasesPrefix),
              let url = URL(string: Identity.appcastURL) else {
            phase = .failed("这个 OctoDot 构建没有更新密钥，无法检查更新。")
            return
        }
        phase = .checking
        let session = URLSession(configuration: .ephemeral)
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
        phase = .downloading
        do {
            let (file, _) = try await URLSession(configuration: .ephemeral).download(from: url)
            try verifier.verifyPayload(at: file, for: manifest)
            let handle = try FileHandle(forReadingFrom: file)
            phase = .installing
            let (ok, message) = await InstallerClient.shared.installUpdate(manifest: manifestData, file: handle)
            try? handle.close()
            try? FileManager.default.removeItem(at: file)
            guard ok else {
                phase = .failed(message)
                return
            }
            relaunch()
        } catch {
            phase = .failed("\(error)")
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
