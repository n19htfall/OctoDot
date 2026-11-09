import AppKit
import InputMethodKit
import os

let log = Logger(subsystem: "OctoDot", category: "ime")  // never logs typed text

/// The input method's core, everything but the launcher (Sources/Launcher):
/// built as a library that the launcher loads, and loads again in place
/// when an update installs a new one, so apps stay connected. Start and stop
/// bracket one core's life in the process; a newer core may start after.
final class Core: NSObject, OctoDotCore {
    /// The images, inside the signed bundle.
    static var dataDirectory: String {
        Bundle.main.resourceURL?.appendingPathComponent("data").path ?? ""
    }

    /// This library's own file (the process's executable is the launcher,
    /// which an update leaves alone): what compiled caches are dated against.
    static let imageURL: URL? = {
        var info = Dl_info()
        guard dladdr(#dsohandle, &info) != 0, let path = info.dli_fname else { return nil }
        return URL(fileURLWithPath: String(cString: path))
    }()

    func start() -> Int32 {
        MainActor.assumeIsolated {
            // The Goose runtime starts on the main thread, before IMK can deliver
            // a key. If the images fail to load, keys pass through to the app.
            let status = Engine.shared.start(dataDirectory: Self.dataDirectory)
            if status != 0 { log.error("engine images failed to load: status \(status, privacy: .public)") }
            Health.start()
            if status == 0 {
                Learning.start()
                Phrases.start()
            }
            Companion.start()
            return status
        }
    }

    func handler(for controller: IMKInputController) -> any OctoDotHandler {
        Handler(controller: controller)
    }

    func stop() {
        MainActor.assumeIsolated {
            Companion.stop()
            CandidatePanel.release()
            SettingsWindow.close()
            Phrases.stop()
            Learning.stop()
            Health.stop()
            if !Engine.shared.stop() {
                log.error("a custom phrase compile was still running; the old engine stays in memory")
            }
        }
    }

    func run(command: String) -> Int32 {
        MainActor.assumeIsolated { Maintenance.run(command) }
    }
}

/// The launcher finds the core through this one symbol, the library's only export.
@_cdecl("octodot_core_v1")
public func octodotCoreV1() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(Core()).toOpaque()
}
