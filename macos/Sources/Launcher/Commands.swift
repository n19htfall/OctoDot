import AppKit
import os

/// The command-line side of the launcher: make install, enable and test run
/// the installed binary with a command; macOS never passes one.
///   --reload     ask the running IME to load the core the bundle names now
///   anything else goes to the core (Sources/IME/Maintenance.swift)
@MainActor
enum Commands {
    static func run(_ command: String) -> Int32 {
        if command == "--reload" { return requestReload() }
        guard let name = Launcher.namedCore(), let core = Launcher.open(name) else {
            print("OctoDot: the core named in Info.plist did not load (see the log)")
            return 1
        }
        return core.run(command: command)
    }

    private static var answer: String?

    /// make install, after copying an update into the installed bundle:
    /// asks the running IME to load it, and waits a moment for its answer.
    private static func requestReload() -> Int32 {
        answer = nil
        let center = DistributedNotificationCenter.default()
        let token = center.addObserver(forName: Launcher.reloadedName, object: nil, queue: .main) { note in
            let running = note.object as? String
            MainActor.assumeIsolated { answer = running ?? "none" }
        }
        center.postNotificationName(Launcher.reloadName, object: nil, userInfo: nil, deliverImmediately: true)
        let deadline = Date().addingTimeInterval(5)
        while answer == nil && Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        center.removeObserver(token)
        let wanted = Launcher.namedCore() ?? "?"
        switch answer {
        case nil:
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: Launcher.bundleID)
                .contains { $0.processIdentifier != getpid() }
            if running {
                print("The running OctoDot did not acknowledge the reload; it may still be using an older core.")
                return 1
            }
            print("No OctoDot is running: it loads \(wanted) when it next starts.")
            return 0
        case wanted:
            print("The running OctoDot now uses \(wanted): no app needs restarting.")
            return 0
        default:
            print("The running OctoDot did not load \(wanted) (it uses \(answer ?? "none")); see:")
            print("  log show --last 2m --predicate 'subsystem == \"OctoDot\"'")
            return 1
        }
    }
}
