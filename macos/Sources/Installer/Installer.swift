import AppKit
import CryptoKit
import Darwin
import Foundation
import os

private let log = Logger(subsystem: "OctoDot", category: "installer")

/// The installer (docs/distribution-and-onboarding.md, section 1): the file
/// and input-source work the sandboxed companion may not do itself. It runs
/// only for the companion that embeds it (main.swift checks every
/// connection), installs only bundles signed by the team with the expected
/// identifier, and checks an update again in full before it swaps it in.
final class Installer: NSObject, InstallerProtocol, @unchecked Sendable {
    private let fm = FileManager.default
    private var home: URL { fm.homeDirectoryForCurrentUser }
    /// The companion this service is inside: OctoDot.app/Contents/XPCServices/<this>.xpc.
    private var companion: URL {
        Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private var embeddedIME: URL { companion.appendingPathComponent("Contents/Resources/OctoDotIME.app") }
    private var inputMethods: URL { home.appendingPathComponent("Library/Input Methods", isDirectory: true) }
    private var installedIME: URL { inputMethods.appendingPathComponent("OctoDotIME.app") }
    private var legacyIME: URL { inputMethods.appendingPathComponent("OctoDot.app") }
    /// Beside the destinations on the same volume, so a bundle moves into
    /// place in one rename; outside Input Methods, where macOS would see a
    /// second copy of the input method.
    private var staging: URL { home.appendingPathComponent("Library/Caches/\(Identity.installer)", isDirectory: true) }
    /// One operation at a time: two installs must never interleave their renames.
    private let lock = NSLock()

    // MARK: Facts

    func facts(reply: @escaping (Data?) -> Void) {
        let facts = currentFacts()
        reply(try? JSONEncoder().encode(facts))
    }

    private func currentFacts() -> SetupFacts {
        let readOnly = ((try? companion.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly) ?? false
        let installed = BundleStamp.of(installedIME)
        return SetupFacts(appPath: companion.path, appOnReadOnlyVolume: readOnly,
                          embedded: BundleStamp.of(embeddedIME), installed: installed,
                          legacyInstalled: bundleID(legacyIME) == Identity.legacyIME,
                          enabled: installed != nil && InputSources.isEnabled(Identity.ime))
    }

    private func bundleID(_ bundle: URL) -> String? {
        (NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")))?["CFBundleIdentifier"] as? String
    }

    // MARK: Installing the IME

    func installIME(reply: @escaping (Bool, String) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        let (ok, message) = install()
        log.info("installIME: \(ok, privacy: .public) \(message, privacy: .public)")
        reply(ok, message)
    }

    /// Copies the embedded IME into place and puts it in use: a reload of the
    /// running IME when only its core changed (no app loses its input
    /// method), a restart when its launcher did.
    private func install() -> (Bool, String) {
        let (ok, message) = installCurrent()
        guard ok, let removed = removeLegacy() else { return (ok, message) }
        return (true, message + " " + removed)
    }

    private func installCurrent() -> (Bool, String) {
        guard let embedded = BundleStamp.of(embeddedIME), Signatures.valid(embeddedIME, identifier: Identity.ime) else {
            return (false, "OctoDot 内的输入法已损坏，或不是 OctoDot 的输入法。")
        }
        let before = BundleStamp.of(installedIME)
        if before == embedded && Signatures.valid(installedIME, identifier: Identity.ime) {
            return (InputSources.register(installedIME), "OctoDot 已是最新。")
        }
        let looksBefore = looks(installedIME)
        do {
            try fm.createDirectory(at: inputMethods, withIntermediateDirectories: true)
            try place(embeddedIME, at: installedIME)
        } catch {
            return (false, "无法安装输入法：\(error.localizedDescription)")
        }
        guard Signatures.valid(installedIME, identifier: Identity.ime) else {
            return (false, "已安装的输入法未能通过校验。")
        }
        guard InputSources.register(installedIME) else {
            return (false, "已安装，但 macOS 没有注册它（TISRegisterInputSource）。")
        }
        if looks(installedIME) != looksBefore { restartMenuAgent() }
        guard let before else { return (true, "已安装 OctoDot \(embedded.version)（\(embedded.build)）。") }
        if before.launcher != embedded.launcher {
            restartIME(Identity.ime)
            return (true, "已更新到 \(embedded.version)（\(embedded.build)），并换了新的启动程序：输入法已重启。" +
                    "基于 Chromium 的应用（Chrome、VS Code）可能需要重新打开一次。")
        }
        let loaded = reloadIME(wanting: embedded.core)
        return (true, "已更新到 \(embedded.version)（\(embedded.build)）；" +
                (loaded ? "正在运行的输入法已开始使用它，无需重启任何应用。"
                        : "将在输入法下次启动时生效。"))
    }

    /// Puts a copy of `source` at `destination` in one step: a staged copy
    /// (a clone, on APFS) swapped with the bundle there, so the path never
    /// holds half a bundle, and a running IME reading it (a reload reads
    /// Info.plist and the core at its path) finds either all old or all new.
    private func place(_ source: URL, at destination: URL) throws {
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let staged = staging.appendingPathComponent(destination.lastPathComponent)
        try? fm.removeItem(at: staged)
        try fm.copyItem(at: source, to: staged)
        if fm.fileExists(atPath: destination.path) {
            guard renamex_np(staged.path, destination.path, UInt32(RENAME_SWAP)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try? fm.removeItem(at: staged)                  // the old bundle, now here
        } else {
            try fm.moveItem(at: staged, to: destination)
        }
    }

    /// The install from before the move (com.example.inputmethod.OctoDot, at
    /// ~/Library/Input Methods/OctoDot.app), removed once the new one is in
    /// place: its input source off, its process quit, its bundle deleted. If
    /// it was among the input sources, the new one takes its place. Its data
    /// is not read or carried over, and stays in its container. nil if there
    /// was none, else what to tell the user.
    private func removeLegacy() -> String? {
        guard bundleID(legacyIME) == Identity.legacyIME else { return nil }
        let wasEnabled = InputSources.isEnabled(Identity.legacyIME)
        InputSources.disable(Identity.legacyIME)
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: Identity.legacyIME)
        for app in running { kill(app.processIdentifier, SIGTERM) }
        do { try fm.removeItem(at: legacyIME) } catch {
            return "无法移除先前的 OctoDot：\(error.localizedDescription)"
        }
        if wasEnabled { InputSources.enable(Identity.ime) }
        restartMenuAgent()
        return "先前的 OctoDot 已移除；它学到的词仍留在 ~/Library/Containers/\(Identity.legacyIME)，可以删除。"
    }

    /// Asks the running IME to load the core its bundle names now, and waits
    /// a moment for its answer (as `OctoDotIME --reload` does).
    private func reloadIME(wanting core: String) -> Bool {
        let center = DistributedNotificationCenter.default()
        let answered = DispatchSemaphore(value: 0)
        let answer = OSAllocatedUnfairLock<String?>(initialState: nil)
        let token = center.addObserver(forName: Notification.Name(Identity.ime + ".reloaded"), object: nil,
                                       queue: nil) { note in
            let core = note.object as? String
            answer.withLock { $0 = core }
            answered.signal()
        }
        defer { center.removeObserver(token) }
        center.postNotificationName(Notification.Name(Identity.ime + ".reload"), object: nil, userInfo: nil,
                                    deliverImmediately: true)
        _ = answered.wait(timeout: .now() + 5)
        return answer.withLock { $0 } == core
    }

    /// Quits the running IME (SIGTERM: it saves the user dictionary first),
    /// and Siri AI, where Spotlight's field lives, which never reconnects to
    /// a new input method process (macOS relaunches it at once; it holds no
    /// user work). macOS starts the new IME when it is next needed.
    private func restartIME(_ bundleID: String) {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        for app in running { kill(app.processIdentifier, SIGTERM) }
        let deadline = Date().addingTimeInterval(2)
        while running.contains(where: { !$0.isTerminated }) && Date() < deadline { usleep(100_000) }
        for app in running where !app.isTerminated { app.forceTerminate() }
        run("/usr/bin/killall", ["Siri AI"])
    }

    /// What the input menu shows of the IME: its icons, its name and how its
    /// mode is declared (Info.plist, less the core's name, which changes with
    /// every build). TextInputMenuAgent caches it.
    private func looks(_ bundle: URL) -> Data {
        var hasher = SHA256()
        let resources = bundle.appendingPathComponent("Contents/Resources")
        let files = ((try? fm.contentsOfDirectory(atPath: resources.path)) ?? []).sorted()
        for name in files where name.hasSuffix(".tiff") || name.hasSuffix(".lproj") {
            let file = name.hasSuffix(".lproj") ? resources.appendingPathComponent(name + "/InfoPlist.strings")
                                                : resources.appendingPathComponent(name)
            if let data = try? Data(contentsOf: file) { hasher.update(data: data) }
        }
        if let info = NSMutableDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")) {
            info.removeObject(forKey: "OctoDotCore")
            if let data = try? PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0) {
                hasher.update(data: data)
            }
        }
        return Data(hasher.finalize())
    }

    /// The input menu reloads OctoDot's name and icons (TextInputMenuAgent
    /// holds no state and comes back at once). Never the indicator at the
    /// caret: killing its processes on 2026-11-08 left apps without it.
    private func restartMenuAgent() { run("/usr/bin/killall", ["TextInputMenuAgent"]) }

    // MARK: Input sources

    func enableIME(reply: @escaping (Bool) -> Void) { reply(InputSources.enable(Identity.ime)) }
    func isEnabled(reply: @escaping (Bool) -> Void) { reply(InputSources.isEnabled(Identity.ime)) }
    func selectIME(reply: @escaping (Bool) -> Void) { reply(InputSources.select(Identity.ime)) }
    func launchIME(reply: @escaping (Bool) -> Void) {
        reply(run("/usr/bin/open", ["-g", installedIME.path]).status == 0)
    }

    // MARK: The IME's own commands

    func preflight(reply: @escaping (Data?) -> Void) {
        reply(runIME(installedIME, ["--preflight"], input: nil).output)
    }

    func exportUserData(reply: @escaping (Data?) -> Void) {
        let result = runIME(installedIME, ["--export"], input: nil)
        reply(result.status == 0 ? result.output : nil)
    }

    func importUserData(_ transfer: Data, reply: @escaping (Bool, String) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard (try? JSONDecoder().decode(Transfer.self, from: transfer)) != nil else {
            reply(false, "这不是 OctoDot 的数据。")
            return
        }
        let result = runIME(installedIME, ["--import"], input: transfer)
        reply(result.status == 0, result.status == 0 ? "数据已恢复。" :
              "输入法无法接收这些数据：" + String(decoding: result.output ?? Data(), as: UTF8.self))
    }

    /// Runs the IME's executable with a command, in the IME's own sandbox
    /// (its entitlements apply, whoever starts it). Command mode never starts
    /// the IMK server, so apps are not handed this short-lived process.
    private func runIME(_ bundle: URL, _ arguments: [String], input: Data?) -> (status: Int32, output: Data?) {
        let executable = bundle.appendingPathComponent("Contents/MacOS/OctoDotIME")
        return run(executable.path, arguments, input: input, timeout: 60)
    }

    // MARK: The companion itself

    func copyToApplications(reply: @escaping (Bool, String) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard Signatures.valid(companion, identifier: Identity.companion) else {
            reply(false, "这份 OctoDot 未能通过校验。")
            return
        }
        let destination = URL(fileURLWithPath: "/Applications/OctoDot.app")
        do {
            try place(companion, at: destination)
            reply(true, destination.path)
        } catch {
            reply(false, "无法把 OctoDot 复制到“应用程序”：\(error.localizedDescription)")
        }
    }

    func installUpdate(manifest: Data, file: FileHandle, reply: @escaping (Bool, String) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        let (ok, message) = update(manifest: manifest, file: file)
        log.info("installUpdate: \(ok, privacy: .public) \(message, privacy: .public)")
        reply(ok, message)
    }

    /// Trusts nothing from the companion: the manifest is verified again, the
    /// download is copied here and checked against it, and the app inside
    /// must be signed by the team (and notarized, when this is a release)
    /// with the build the manifest names, before it replaces this one.
    private func update(manifest json: Data, file: FileHandle) -> (Bool, String) {
        guard let key = (NSDictionary(contentsOf: companion.appendingPathComponent("Contents/Info.plist"))?[
                  "OctoDotUpdatePublicKey"] as? String), !key.isEmpty,
              let verifier = try? UpdateVerifier(publicKeyBase64: key, releasesPrefix: Identity.releasesPrefix),
              let running = BundleStamp.of(companion)?.build else {
            return (false, "这个 OctoDot 构建没有更新密钥。")
        }
        let manifest: UpdateManifest
        do { manifest = try verifier.verify(json, runningBuild: running) } catch {
            return (false, "\(error)")
        }
        let work = staging.appendingPathComponent("update", isDirectory: true)
        try? fm.removeItem(at: work)
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            let archive = work.appendingPathComponent("OctoDot.zip")
            fm.createFile(atPath: archive.path, contents: nil)
            let out = try FileHandle(forWritingTo: archive)
            try file.seek(toOffset: 0)
            while let chunk = try file.read(upToCount: 1 << 20), !chunk.isEmpty { try out.write(contentsOf: chunk) }
            try out.close()
            try verifier.verifyPayload(at: archive, for: manifest)
            guard run("/usr/bin/ditto", ["-x", "-k", archive.path, work.path]).status == 0 else {
                return (false, "无法解压更新。")
            }
        } catch {
            return (false, "\(error)")
        }
        let app = work.appendingPathComponent("OctoDot.app")
        guard Signatures.valid(app, identifier: Identity.companion), BundleStamp.of(app)?.build == manifest.build
        else { return (false, "更新里的应用不是 OctoDot，或不是清单所说的构建。") }
        if Signatures.isDeveloperID(companion) && !Signatures.notarized(app) {
            return (false, "这份更新没有经过 Apple 公证。")
        }
        do { try place(app, at: companion) } catch {
            return (false, "无法替换 OctoDot：\(error.localizedDescription)")
        }
        try? fm.removeItem(at: work)
        return (true, "已更新到 OctoDot \(manifest.version)。")
    }

    // MARK: Uninstalling

    func uninstall(wipe: Bool, reply: @escaping (Bool, String) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        InputSources.disable(Identity.ime)
        if wipe && fm.fileExists(atPath: installedIME.path) {
            let wiped = runIME(installedIME, ["--wipe"], input: nil)
            guard wiped.status == 0 else {
                reply(false, "无法清除你的数据，什么都没有移除。")
                return
            }
        }
        restartIME(Identity.ime)
        do {
            if fm.fileExists(atPath: installedIME.path) { try fm.removeItem(at: installedIME) }
            try? fm.removeItem(at: staging)
            restartMenuAgent()
            var trashed: NSURL?
            try fm.trashItem(at: companion, resultingItemURL: &trashed)
            reply(true, wipe ? "OctoDot 和你的数据已移除。" : "OctoDot 已移除，你的数据已保留。")
        } catch {
            reply(false, "无法移除 OctoDot：\(error.localizedDescription)")
        }
    }

    // MARK: Processes

    @discardableResult
    private func run(_ path: String, _ arguments: [String], input: Data? = nil,
                     timeout: TimeInterval = 10) -> (status: Int32, output: Data?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        let inPipe = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : inPipe
        do { try process.run() } catch { return (-1, nil) }
        if let input {
            DispatchQueue.global().async {
                try? inPipe.fileHandleForWriting.write(contentsOf: input)
                try? inPipe.fileHandleForWriting.close()
            }
        }
        let collected = OSAllocatedUnfairLock(initialState: Data())
        let reading = DispatchGroup()
        reading.enter()
        DispatchQueue.global().async {
            let data = out.fileHandleForReading.readDataToEndOfFile()
            collected.withLock { $0 = data }
            reading.leave()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate() }
        reading.wait()
        process.waitUntilExit()
        return (process.terminationStatus, collected.withLock { $0 })
    }
}
