import Carbon
import Foundation
import InputMethodKit

/// Commands for installing and testing; macOS never passes these.
///   --register   register the bundle with Text Input Sources (make install)
///   --enable     add its input modes to the user's input sources
///   --disable    remove them again
///   --selftest [--hold N]
///                start the engine and the IMK server inside the sandbox,
///                type one phrase and print a JSON verdict. With --hold, keep
///                serving for N seconds, so sandbox-test.sh can check from
///                outside that the Mach name really got registered.
@MainActor
enum Maintenance {
    static func run(_ command: String) -> Int32 {
        switch command {
        case "--register":
            let status = TISRegisterInputSource(Bundle.main.bundleURL as CFURL)
            print("TISRegisterInputSource: \(status)")
            return status == noErr ? 0 : 1
        case "--enable":
            return forEachSource { TISEnableInputSource($0) }
        case "--disable":
            return forEachSource { TISDisableInputSource($0) }
        case "--selftest":
            return selfTest()
        default:
            print("usage: OctoDot [--register | --enable | --disable | --selftest]")
            return 2
        }
    }

    private static func ourSources() -> [TISInputSource] {
        guard let id = Bundle.main.bundleIdentifier else { return [] }
        let filter = [kTISPropertyBundleID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() else { return [] }
        return (0..<CFArrayGetCount(list)).map {
            unsafeBitCast(CFArrayGetValueAtIndex(list, $0), to: TISInputSource.self)
        }
    }

    private static func forEachSource(_ action: (TISInputSource) -> OSStatus) -> Int32 {
        let sources = ourSources()
        guard !sources.isEmpty else {
            print("no input sources registered for \(Bundle.main.bundleIdentifier ?? "?"); run --register first")
            return 1
        }
        var failed = false
        for source in sources {
            let status = action(source)
            let id = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
                .map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String } ?? "?"
            print("\(id): \(status)")
            failed = failed || status != noErr
        }
        return failed ? 1 : 0
    }

    /// The parts a real launch needs, run inside the sandbox: the Goose
    /// runtime starts and the engine answers a key sequence. Whether the IMK
    /// server's Mach name registered cannot be told from here: IMKServer
    /// returns an object even when registration fails (it only logs "could
    /// not register"), so sandbox-test.sh looks the name up from outside.
    private static func selfTest() -> Int32 {
        let sandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        Engine.shared.start()
        let name = Bundle.main.object(forInfoDictionaryKey: "InputMethodConnectionName") as? String ?? ""
        let server = IMKServer(name: name, bundleIdentifier: Bundle.main.bundleIdentifier)

        let session = Engine.shared.newSession(clientBundleID: "selftest")
        for scalar in "nihao".unicodeScalars {
            _ = Engine.shared.key(session, key: .other, codepoint: scalar.value, modifiers: [])
        }
        let result = Engine.shared.key(session, key: .space, codepoint: 32, modifiers: [])
        let committed = result.contains(.hasCommit) && Engine.shared.snapshot(session).commit == "你好"

        let ok = sandboxed && committed
        print("""
            {"sandboxed": \(sandboxed), "engine_commit": \(committed), "ok": \(ok)}
            """)
        fflush(stdout)

        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--hold"), flag + 1 < arguments.count,
           let seconds = Double(arguments[flag + 1]) {
            withExtendedLifetime(server) {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
            }
        }
        return ok ? 0 : 1
    }
}
