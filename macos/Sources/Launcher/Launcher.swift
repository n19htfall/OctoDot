import AppKit
import InputMethodKit
import os

let log = Logger(subsystem: "OctoDot", category: "launcher")  // never logs typed text

/// The input method's process: the IMK server, and the core it loads.
///
/// Apps keep their connection to an input method's process for as long as
/// they run, and many never make a new one: Chromium-based apps (Chrome,
/// Typora, VS Code) and Spotlight's field (in Siri AI) type nothing after
/// the process is replaced, until they are restarted. So an update does not
/// replace the process. Everything that changes, the engine, the images'
/// reader, the candidate window, the learning, is the core: a library in
/// Contents/Frameworks, named in Info.plist (OctoDotCore). `OctoDot
/// --reload`, which make install runs after copying an update in, makes the
/// running process load the new core in place of the old one, and every
/// app's connection stays. Only a change to this launcher, which is small
/// and rarely changes, needs a new process.
@main
@MainActor
enum Launcher {
    /// Kept alive for the life of the process: IMK serves clients through it.
    private static var server: IMKServer?
    private static var sources: [any DispatchSourceProtocol] = []
    private static var reloadObserver: ReloadObserver?

    // IMK calls the controllers on the main thread, but its methods are not
    // main-actor isolated, so the state they read is marked unsafe instead;
    // nothing else touches it, and only on the main thread.
    /// The core loaded now, and its file's name.
    nonisolated(unsafe) static var core: (any OctoDotCore)?
    nonisolated(unsafe) private static var coreName: String?
    /// Counts loads: a controller whose handler came from an earlier load makes a new one.
    nonisolated(unsafe) static var generation = 0
    /// Every client's controller, to retire their handlers before a reload.
    nonisolated(unsafe) static let controllers = NSHashTable<OctoInputController>.weakObjects()
    private static var retry: Timer?
    private static var reconciliation: Timer?
    private static var failureDelay: TimeInterval = 5
    // Swift libraries stay mapped; reuse each core object on retries rather
    // than adding another dlopen reference every time a startup fails.
    private static var loadedCores: [String: any OctoDotCoreV2] = [:]

    private static let switcher = ReloadCoordinator<LoadedCore>(
        open: { name in
            if let core = loadedCores[name] { return LoadedCore(core) }
            guard let core = open(name) as? any OctoDotCoreV2 else { return nil }
            loadedCores[name] = core
            return LoadedCore(core)
        },
        snapshot: { snapshotData() },
        removeSnapshot: { path in
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent())
        },
        canRetire: { controllers.allObjects.allSatisfy { $0.canRetire() } },
        retire: { for controller in controllers.allObjects { controller.retire() } },
        publish: { generation in
            core = generation?.core.core
            coreName = generation?.name
            Launcher.generation += 1
        })

    static var bundleID: String { Bundle.main.bundleIdentifier ?? "OctoDot" }
    static var reloadName: Notification.Name { Notification.Name(bundleID + ".reload") }
    static var reloadedName: Notification.Name { Notification.Name(bundleID + ".reloaded") }

    static func main() {
        // Maintenance commands (make install / enable / test) start with "--".
        // macOS itself launches the input method with no such argument.
        if let command = CommandLine.arguments.dropFirst().first(where: { $0.hasPrefix("--") }) {
            exit(Commands.run(command))
        }

        reload(reason: "launch")
        watchInstalledCore()
        handleTermination()
        let observer = ReloadObserver()
        DistributedNotificationCenter.default().addObserver(
            observer, selector: #selector(ReloadObserver.reload(_:)), name: reloadName, object: nil,
            suspensionBehavior: .deliverImmediately)
        reloadObserver = observer

        guard let name = Bundle.main.object(forInfoDictionaryKey: "InputMethodConnectionName") as? String,
              let server = IMKServer(name: name, bundleIdentifier: Bundle.main.bundleIdentifier)
        else {
            fatalError("OctoDot: cannot create the IMK server")
        }
        Self.server = server
        NSApplication.shared.run()
    }

    // MARK: Loading the core

    /// The core the bundle names now, read from disk: an update replaces
    /// Info.plist under the running process, and Bundle.main keeps the old one.
    static func namedCore() -> String? {
        let plist = Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist")
        return NSDictionary(contentsOf: plist)?["OctoDotCore"] as? String
    }

    /// Loads a core library and makes its core object. Every build has its
    /// own file name and Swift module name, so a new core loads beside the
    /// old one without a clash; the old one's code stays mapped (Swift code
    /// cannot be unloaded), its memory released by its stop.
    static func open(_ core: String) -> (any OctoDotCore)? {
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/" + core).path
        guard let image = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            let why = dlerror().map { String(cString: $0) } ?? "unknown"
            log.error("core \(core, privacy: .public) did not load: \(why, privacy: .public)")
            return nil
        }
        guard let entry = dlsym(image, "octodot_core_v1") else {
            log.error("core \(core, privacy: .public) has no entry point octodot_core_v1")
            return nil
        }
        typealias Entry = @convention(c) () -> UnsafeMutableRawPointer
        let object = Unmanaged<AnyObject>.fromOpaque(unsafeBitCast(entry, to: Entry.self)()).takeRetainedValue()
        guard let loaded = object as? any OctoDotCore else {
            log.error("core \(core, privacy: .public) does not answer the launcher's protocol")
            return nil
        }
        return loaded
    }

    /// Retain the data of each generation separately: the installer swaps
    /// the bundle underneath this process, and rollback must read the old
    /// data, not the new bundle's files.
    private static func snapshotData() -> String? {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("OctoDot-core-\(UUID().uuidString)", isDirectory: true)
        let source = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/data", isDirectory: true)
        do {
            return try GenerationData.snapshot(from: source, in: parent).path
        } catch {
            log.error("cannot preserve core data")
            return nil
        }
    }

    /// A switch waits for compositions and worker jobs, then rolls back to
    /// the previous generation if starting the new one fails.
    static func reload(reason: String) {
        guard let next = namedCore() else {
            log.error("Info.plist names no core")
            scheduleRetry(after: failureDelay)
            return
        }
        switch switcher.reload(next) {
        case .active:
            retry?.invalidate()
            retry = nil
            failureDelay = 5
            log.notice("core \(next, privacy: .public) active at \(reason, privacy: .public)")
        case .deferred:
            scheduleRetry(after: 0.5)
        case .failed:
            log.error("core \(next, privacy: .public) did not activate; the previous core is retained when possible")
            scheduleRetry(after: failureDelay)
            failureDelay = min(failureDelay * 2, 60)
        }
    }

    private static func stopCore() {
        retry?.invalidate()
        retry = nil
        reconciliation?.invalidate()
        reconciliation = nil
        switcher.stop()
    }

    /// A notification or its acknowledgement can be lost. Independently
    /// compare the installed generation with the one that actually started.
    private static func watchInstalledCore() {
        reconciliation = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard retry == nil, let installed = namedCore(), installed != coreName else { return }
                reload(reason: "reconcile")
            }
        }
    }

    private static func scheduleRetry(after delay: TimeInterval) {
        guard retry == nil else { return }
        retry = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated {
                retry = nil
                reload(reason: "retry")
            }
        }
    }

    /// Asked over a distributed notification; answers with the core in use.
    fileprivate static func reloadRequested() {
        reload(reason: "update")
        DistributedNotificationCenter.default().postNotificationName(
            reloadedName, object: coreName ?? "none", userInfo: nil, deliverImmediately: true)
    }

    // MARK: Ending

    /// Logout quits the app; make install and kill send SIGTERM. Either way
    /// the core stops cleanly first: learning saved, the run marked clean.
    private static func handleTermination() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { _ in
            MainActor.assumeIsolated { stopCore() }
        }
        signal(SIGTERM, SIG_IGN)                // handled below, on the main queue
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler {
            MainActor.assumeIsolated {
                stopCore()
                exit(0)
            }
        }
        term.resume()
        sources.append(term)
    }
}

@MainActor
private final class LoadedCore: ReloadableGeneration {
    let core: any OctoDotCoreV2
    init(_ core: any OctoDotCoreV2) { self.core = core }
    func start(dataDirectory: String) -> Int32 { core.start(dataDirectory: dataDirectory) }
    func readyForReload() -> Bool { core.readyForReload() }
    func stopForReload() -> Bool { core.stopForReload() }
    func discard() { core.stop() }
}

/// Receives the reload request. A selector observer, because only that form
/// takes a suspension behavior: an input method is never the active app,
/// and AppKit holds distributed notifications back from inactive apps.
private final class ReloadObserver: NSObject {
    @objc func reload(_ note: Notification) {
        MainActor.assumeIsolated { Launcher.reloadRequested() }
    }
}
