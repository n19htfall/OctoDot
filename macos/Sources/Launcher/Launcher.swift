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

    /// Puts the core the bundle names in use, unless it already is. The new
    /// core loads first, and if it does not, the old one keeps serving. Then
    /// every client's handler retires (a composition in progress ends as on
    /// a focus change), the old core stops (learning saved, its engine's
    /// memory released), and the new one starts. Each controller makes a
    /// handler from it on its next call.
    static func reload(reason: String) {
        guard let next = namedCore() else {
            log.error("Info.plist names no core")
            return
        }
        guard next != coreName else { return }
        guard let loaded = open(next) else { return }
        stopCore()
        core = loaded
        coreName = next
        generation += 1
        let status = loaded.start()
        log.notice("core \(next, privacy: .public) started at \(reason, privacy: .public): status \(status, privacy: .public)")
    }

    private static func stopCore() {
        for controller in controllers.allObjects { controller.retire() }
        core?.stop()
        core = nil
        coreName = nil
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

/// Receives the reload request. A selector observer, because only that form
/// takes a suspension behavior: an input method is never the active app,
/// and AppKit holds distributed notifications back from inactive apps.
private final class ReloadObserver: NSObject {
    @objc func reload(_ note: Notification) {
        MainActor.assumeIsolated { Launcher.reloadRequested() }
    }
}
