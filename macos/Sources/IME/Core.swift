import AppKit
import InputMethodKit
import os

let log = Logger(subsystem: "OctoDot", category: "ime")  // never logs typed text

/// The input method's core, everything but the launcher (Sources/Launcher):
/// built as a library that the launcher loads, and loads again in place
/// when an update installs a new one, so apps stay connected. Start and stop
/// bracket one core's life in the process; a newer core may start after.
// The launcher calls the protocol only on the main thread; each entry point
// checks that rule with MainActor.assumeIsolated.
final class Core: NSObject, OctoDotCoreV2, @unchecked Sendable {
    /// The images, inside the signed bundle.
    @MainActor private static var generationDirectory: String?
    @MainActor
    static var dataDirectory: String {
        generationDirectory ?? Bundle.main.resourceURL?.appendingPathComponent("data").path ?? ""
    }

    /// The grammar model the bundle pins, which lives outside it, in the
    /// folder shared with the companion (GrammarPin); nil in a bundle with no pin.
    @MainActor static var grammarPin: GrammarPin? { GrammarPin(contentsOf: URL(fileURLWithPath: dataDirectory + "/grammar.pin")) }

    /// Starts the engine on the bundle's images and the shared grammar model.
    @MainActor @discardableResult
    static func startEngine() -> Int32 {
        Engine.shared.start(dataDirectory: dataDirectory, grammarFolder: grammarPin?.folder?.path)
    }

    /// This library's own file (the process's executable is the launcher,
    /// which an update leaves alone): what compiled caches are dated against.
    static let imageURL: URL? = {
        var info = Dl_info()
        guard dladdr(#dsohandle, &info) != 0, let path = info.dli_fname else { return nil }
        return URL(fileURLWithPath: String(cString: path))
    }()

    private var servicesStarted = false

    func start() -> Int32 { start(dataDirectory: Bundle.main.resourceURL?.appendingPathComponent("data").path ?? "") }

    func start(dataDirectory: String) -> Int32 {
        MainActor.assumeIsolated {
            Self.generationDirectory = dataDirectory
            // The Goose runtime starts on the main thread, before IMK can deliver
            // a key. If the images fail to load, keys pass through to the app.
            let status = Self.startEngine()
            guard status == 0 else {
                log.error("engine images failed to load: status \(status, privacy: .public)")
                return status
            }
            Health.start()
            Learning.start()
            Phrases.start()
            Companion.start()
            servicesStarted = true
            return status
        }
    }

    func readyForReload() -> Bool {
        MainActor.assumeIsolated { !Engine.shared.pump().contains(.pending) }
    }

    func stopForReload() -> Bool {
        guard readyForReload() else { return false }
        // Do not tear down the only in-memory copy of learning if saving it
        // failed. The launcher keeps this generation and retries later.
        guard MainActor.assumeIsolated({ Learning.saveNow() }) else { return false }
        stop()
        return MainActor.assumeIsolated { !Engine.shared.isStarted }
    }

    func handler(for controller: IMKInputController) -> any OctoDotHandler {
        Handler(controller: controller)
    }

    func stop() {
        MainActor.assumeIsolated {
            if servicesStarted {
                Companion.stop()
                CandidatePanel.release()
                SettingsWindow.close()
                Phrases.stop()
                Learning.stop()
                Health.stop()
                servicesStarted = false
            }
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
