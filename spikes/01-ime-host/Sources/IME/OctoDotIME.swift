import AppKit
import InputMethodKit

@main
@MainActor
enum OctoDotIME {
    /// Kept alive for the life of the process: IMK serves clients through it.
    private static var server: IMKServer?

    static func main() {
        // Maintenance commands (make install / enable / test) start with "--".
        // macOS itself launches the input method with no such argument.
        if let command = CommandLine.arguments.dropFirst().first(where: { $0.hasPrefix("--") }) {
            exit(Maintenance.run(command))
        }

        // The Goose runtime starts on the main thread, before IMK can deliver
        // a key. Every engine call stays on this thread (see Engine).
        Engine.shared.start()

        guard let name = Bundle.main.object(forInfoDictionaryKey: "InputMethodConnectionName") as? String,
              let server = IMKServer(name: name, bundleIdentifier: Bundle.main.bundleIdentifier)
        else {
            fatalError("OctoDot: cannot create the IMK server")
        }
        Self.server = server
        NSApplication.shared.run()
    }
}
